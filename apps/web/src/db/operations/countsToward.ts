import { db } from '../internal';
import {
  SyncOperationType,
  countsTowardEventId,
  countsTowardProblem,
  findTransitiveParentCompounds,
  isFrozenRowReachedByEvent,
  planCountsTowardAction,
  resolveContributionState,
  type CompoundChild,
  type CountsTowardAction,
  type CountsTowardProblem,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { stampTaskCachesAuthored } from './taskEvents';
import { refreshDerivedBaselines } from './derivedCounters';
import { propagateToLinkedRows } from './tasks.sharedCounter';
import { reDeriveSealedBoardsForTasks } from './sealing';
import { refreshWatchersForBoards, resolveAffectedBoardIds } from './boardLifecycle';
import { runBoardCascadeForTasks } from './orchestration';
import { buildWindowContext } from './windowContext';

/**
 * countsToward.ts — "counts toward", web data half
 * (docs/SHARED_COUNTER_SETTINGS.md §3b). Swift twin:
 * `AppDatabase+CountsToward.swift`. The pure rules live in `@oybc/shared`
 * (`countsToward.ts`); this module writes them.
 *
 *   - {@link applyCountsTowardForTasks} — the cascade hook. Runs at the end of
 *     every `runBoardCascadeForTasks` (the one choke point every local write,
 *     the pull paths and the late-log re-derivation go through), inside the
 *     same transaction: for each changed task and each compound containing it,
 *     compare its derived lifetime completion with the deterministic event on
 *     its counter root and insert / revise / tombstone it (version bump +
 *     enqueue), then run the root's own cascade exactly like a hand log.
 *   - {@link setCountsToward} — the write-time entry that sets / clears the
 *     flag (validated by `countsTowardProblem`).
 *   - {@link countContributorsOf} — the guard the kind switch and the delete
 *     paths read.
 */

/**
 * Deepest chain of counts-toward cascades one write may trigger (a counter's
 * copy inside another contributor). `countsTowardProblem` refuses a
 * self-feeding loop; this bound is the runtime belt.
 */
export const MAX_COUNTS_TOWARD_DEPTH = 3;

/** Snapshot a caller already loaded (the board cascade's lookups). */
export interface CountsTowardLookups {
  allTasks: Task[];
  /** Live compound links. */
  allChildren: CompoundChild[];
  /** Non-deleted events grouped by `taskId`. */
  eventsByTaskId: Record<string, TaskEvent[]>;
}

/** Refused {@link setCountsToward}; nothing is written. */
export class CountsTowardError extends Error {
  /** Why it was refused. */
  readonly code: CountsTowardProblem | 'task-missing';

  /**
   * @param code - The refusal reason.
   * @param message - Developer-facing detail.
   */
  constructor(code: CountsTowardProblem | 'task-missing', message: string) {
    super(message);
    this.name = 'CountsTowardError';
    this.code = code;
  }
}

/** The transaction scope every entry point here needs. */
const COUNTS_TOWARD_TABLES = [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue];

/**
 * Live tasks that count toward `counterId`.
 *
 * Must run inside (or outside) any transaction covering `tasks`.
 *
 * @param counterId - The counter root.
 * @returns The contributing rows.
 */
export async function countContributorsOf(counterId: string): Promise<Task[]> {
  return db.tasks.filter((t) => !t.isDeleted && t.countsTowardCounterId === counterId).toArray();
}

/**
 * The cascade hook (§3b). For every task in `changedTaskIds` and every
 * compound transitively containing one, plan the counts-toward write
 * (`planCountsTowardAction`) and apply it; then re-cascade each counter root
 * whose events moved. Idempotent: a replay with no state change writes
 * nothing.
 *
 * MUST run inside the caller's `rw` transaction over `boards`, `boardTasks`,
 * `tasks`, `compoundChildren`, `taskEvents`, `syncQueue`.
 *
 * @param changedTaskIds - Tasks whose derived state may have changed.
 * @param now - The write instant (`createdAt` / `updatedAt` of written rows).
 * @param depth - Chain depth (0 for a top-level cascade).
 * @param lookups - A snapshot the caller already holds, if any.
 */
export async function applyCountsTowardForTasks(
  changedTaskIds: Iterable<string>,
  now: string,
  depth = 0,
  lookups?: CountsTowardLookups,
): Promise<void> {
  if (depth > MAX_COUNTS_TOWARD_DEPTH) return;
  const allChildren = lookups?.allChildren ?? (await db.compoundChildren.filter((c) => !c.isDeleted).toArray());
  const allTasks = lookups?.allTasks ?? (await db.tasks.toArray());
  const taskById: Record<string, Task> = {};
  for (const t of allTasks) taskById[t.id] = t;

  const candidates = new Set<string>();
  for (const id of changedTaskIds) {
    candidates.add(id);
    for (const parent of findTransitiveParentCompounds(id, allChildren)) candidates.add(parent);
  }
  const ids = [...candidates].filter((id) => taskById[id] !== undefined);
  if (ids.length === 0) return;

  const stored = await db.taskEvents.bulkGet(ids.map(countsTowardEventId));
  if (ids.every((id, i) => taskById[id].countsTowardCounterId == null && stored[i] === undefined)) return;

  const eventsByTaskId = lookups?.eventsByTaskId ?? (await buildWindowContext()).eventsByTaskId;
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of allChildren) (childrenByCompound[c.compoundTaskId] ??= []).push(c);

  const reach = new Map<string, string[]>();
  const noteReach = (rootId: string, occurredAt: string): void => {
    const list = reach.get(rootId) ?? [];
    if (!list.includes(occurredAt)) list.push(occurredAt);
    reach.set(rootId, list);
  };

  for (const [i, id] of ids.entries()) {
    const task = taskById[id];
    const existing = stored[i];
    if (task.countsTowardCounterId == null && existing === undefined) continue;
    const state = resolveContributionState(task, childrenByCompound, taskById, eventsByTaskId);
    const action = planCountsTowardAction(task, taskById, state, existing);
    if (!action) continue;
    await writeCountsTowardAction(action, task.userId, existing, now);
    noteReach(action.rootId, action.occurredAt);
    if (action.kind === 'revise') noteReach(action.previousRootId, action.previousOccurredAt);
  }

  for (const [rootId, instants] of reach) await cascadeCounterRoot(rootId, instants, now, depth);
}

/** Apply one planned write: the event row + its sync entry. */
async function writeCountsTowardAction(
  action: CountsTowardAction,
  userId: string,
  existing: TaskEvent | undefined,
  now: string,
): Promise<void> {
  if (action.kind === 'insert') {
    const event: TaskEvent = {
      id: action.eventId,
      userId,
      taskId: action.rootId,
      kind: 'increment',
      delta: action.delta,
      occurredAt: action.occurredAt,
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    };
    await db.taskEvents.put(event);
    await addToSyncQueue('taskEvents', event.id, SyncOperationType.CREATE, event);
    return;
  }
  if (!existing) return;
  if (action.kind === 'tombstone') {
    const tombstoned: TaskEvent = { ...existing, isDeleted: true, deletedAt: now, updatedAt: now, version: existing.version + 1 };
    await db.taskEvents.put(tombstoned);
    await addToSyncQueue('taskEvents', tombstoned.id, SyncOperationType.DELETE, tombstoned);
    return;
  }
  const { deletedAt: _cleared, ...live } = existing;
  const revised: TaskEvent = {
    ...live,
    taskId: action.rootId,
    kind: 'increment',
    delta: action.delta,
    occurredAt: action.occurredAt,
    isDeleted: false,
    updatedAt: now,
    version: existing.version + 1,
  };
  await db.taskEvents.put(revised);
  await addToSyncQueue('taskEvents', revised.id, SyncOperationType.UPDATE, revised);
}

/**
 * A counter root's events moved: the same tail a hand log runs
 * (`incrementSharedCounter` / `undoLastCounterLog`) — restamp the root's
 * lifetime caches from events, refresh window-stamped baselines, propagate to
 * live copies + cascade their boards (which re-enters the hook one level
 * deeper for chained contributors), reach frozen copies whose window holds
 * any moved instant, re-derive sealed boards, refresh watchers.
 */
async function cascadeCounterRoot(rootId: string, instants: string[], now: string, depth: number): Promise<void> {
  const root = await db.tasks.get(rootId);
  if (!root || root.isDeleted) return;
  await stampTaskCachesAuthored(rootId, now);
  await refreshDerivedBaselines(rootId);
  const after = await db.tasks.get(rootId);
  const [first, ...rest] = instants;
  await propagateToLinkedRows(rootId, after?.currentCount ?? 0, now, first, { countsTowardDepth: depth + 1 });
  if (rest.length > 0) {
    const linked = await db.tasks.where('sharedCounterId').equals(rootId).filter((t) => !t.isDeleted).toArray();
    const frozen = linked.filter((t) => rest.some((at) => isFrozenRowReachedByEvent(t, at, now))).map((t) => t.id);
    if (frozen.length > 0) await runBoardCascadeForTasks(frozen, { countsTowardDepth: depth + 1 });
  }
  await reDeriveSealedBoardsForTasks([rootId]);
  const watcherSeedIds = await resolveAffectedBoardIds([rootId]);
  if (watcherSeedIds.size > 0) await refreshWatchersForBoards(watcherSeedIds);
}

/**
 * Set (or clear, with `counterId: null`) what a task counts toward, then run
 * its cascade so the event follows at once (a task already complete mints
 * its increment; a cleared one tombstones it). Authored: version bump +
 * UPDATE enqueue; a clear removes both fields (clearable on sync).
 *
 * @param taskId - The contributing task.
 * @param counterId - The Discrete counter root, or `null` to stop counting.
 * @param amount - Increment per completion (absent = 1).
 * @throws {CountsTowardError} with the `countsTowardProblem` code when refused.
 */
export async function setCountsToward(taskId: string, counterId: string | null, amount?: number): Promise<void> {
  await db.transaction('rw', COUNTS_TOWARD_TABLES, async () => {
    const now = currentTimestamp();
    const task = await db.tasks.get(taskId);
    if (!task || task.isDeleted) throw new CountsTowardError('task-missing', `setCountsToward: ${taskId} is not a live task`);
    if (counterId != null) {
      const problem = countsTowardProblem({
        task,
        targetId: counterId,
        amount,
        tasks: await db.tasks.toArray(),
        children: await db.compoundChildren.filter((c) => !c.isDeleted).toArray(),
      });
      if (problem) throw new CountsTowardError(problem, `setCountsToward: ${taskId} → ${counterId} refused (${problem})`);
    }
    const { countsTowardCounterId: _id, countsTowardAmount: _amount, ...rest } = task;
    const next: Task = {
      ...rest,
      ...(counterId != null ? { countsTowardCounterId: counterId } : {}),
      ...(counterId != null && amount !== undefined ? { countsTowardAmount: amount } : {}),
      updatedAt: now,
      version: task.version + 1,
    };
    await db.tasks.put(next);
    await addToSyncQueue('tasks', taskId, SyncOperationType.UPDATE, next);
    await runBoardCascadeForTasks([taskId]);
  });
}

/**
 * Run the counts-toward hook for `taskIds` in its own transaction — for a
 * write path that has no board cascade of its own (a container created from
 * already-done sub-tasks counts at once).
 *
 * @param taskIds - The tasks to re-derive.
 */
export async function syncCountsTowardFor(taskIds: string[]): Promise<void> {
  await db.transaction('rw', COUNTS_TOWARD_TABLES, () => applyCountsTowardForTasks(taskIds, currentTimestamp()));
}

/**
 * Clear `countsTowardCounterId` on every live contributor of a counter that is
 * being deleted (§3e). Authored: version bump + UPDATE enqueue; the events
 * stay with the (deleted) root. Must run inside the delete's transaction.
 *
 * @param counterId - The counter root being deleted.
 * @param now - The delete instant.
 */
export async function unflagContributorsOf(counterId: string, now: string): Promise<void> {
  for (const c of await countContributorsOf(counterId)) {
    const { countsTowardCounterId: _id, countsTowardAmount: _amount, ...rest } = c;
    const next: Task = { ...rest, updatedAt: now, version: c.version + 1 };
    await db.tasks.put(next);
    await addToSyncQueue('tasks', c.id, SyncOperationType.UPDATE, next);
  }
}
