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
import { writeLinkedRowPropagation } from './tasks.sharedCounter';
import { reDeriveSealedBoardsForTasks } from './sealing';
import { refreshWatchersForBoards, resolveAffectedBoardIds } from './boardLifecycle';
import { runBoardCascadeForTasks } from './orchestration';

/**
 * countsToward.ts — "counts toward", web data half
 * (docs/SHARED_COUNTER_SETTINGS.md §3b). Swift twin:
 * `AppDatabase+CountsToward.swift`. The pure rules live in `@oybc/shared`
 * (`countsToward.ts`); this module writes them.
 *
 *   - {@link writeCountsTowardForTasks} / {@link finishCountsTowardRoots} —
 *     the cascade hook, wrapped around the board pass of every
 *     `runBoardCascadeForTasks` (the one choke point every local write, the
 *     pull paths and the late-log re-derivation go through), inside the same
 *     transaction: for each changed task and each compound containing it,
 *     compare its derived lifetime completion with the deterministic event on
 *     its counter root and insert / revise / tombstone it (version bump +
 *     enqueue), then write the root's log like a hand log; the board pass
 *     derives the copies' boards, the finish phase re-derives sealed boards
 *     and refreshes watchers.
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

/** What {@link writeCountsTowardForTasks} touched, for the caller's board pass. */
export interface CountsTowardWrites {
  /** Counter roots + live / reached-frozen copies whose boards must re-derive. */
  cascadeIds: Set<string>;
  /** Counter roots whose events moved (sealed re-derive + watchers after the pass). */
  rootIds: Set<string>;
}

/**
 * The cascade hook, WRITE phase (§3b). For every task in `changedTaskIds` and
 * every compound transitively containing one, plan the counts-toward write
 * (`planCountsTowardAction`) and apply it (event row, version bump, enqueue);
 * then, for each counter root whose events moved, run a hand log's writes —
 * restamp the root's lifetime caches, refresh window-stamped baselines,
 * propagate to its live copies — and re-enter one level deeper for
 * contributors that contain those copies. Board derivation is left to the
 * caller's ONE pass over `cascadeIds` (so a copy on the contributor's own
 * board is read with the new increment and its bingo lands in that pass's
 * result map); {@link finishCountsTowardRoots} runs after it. Idempotent: a
 * replay with no state change writes nothing.
 *
 * Cheap when nothing counts toward anything: the candidate rows and their
 * deterministic event ids are read by key; the whole-table loads happen only
 * when a candidate is flagged or already holds an event.
 *
 * MUST run inside the caller's `rw` transaction over `boards`, `boardTasks`,
 * `tasks`, `compoundChildren`, `taskEvents`, `syncQueue`.
 *
 * @param changedTaskIds - Tasks whose derived state may have changed.
 * @param now - The write instant (`createdAt` / `updatedAt` of written rows).
 * @param liveChildren - The live compound links, when the caller already loaded them.
 * @param depth - Chain depth (0 for a top-level call).
 * @returns The ids the caller's board pass must add, and the roots to finish.
 */
export async function writeCountsTowardForTasks(
  changedTaskIds: Iterable<string>,
  now: string,
  liveChildren?: CompoundChild[],
  depth = 0,
): Promise<CountsTowardWrites> {
  const out: CountsTowardWrites = { cascadeIds: new Set(), rootIds: new Set() };
  if (depth > MAX_COUNTS_TOWARD_DEPTH) return out;
  const allChildren = liveChildren ?? (await db.compoundChildren.filter((c) => !c.isDeleted).toArray());
  const candidates = new Set<string>();
  for (const id of changedTaskIds) {
    candidates.add(id);
    for (const parent of findTransitiveParentCompounds(id, allChildren)) candidates.add(parent);
  }
  const candidateIds = [...candidates];
  if (candidateIds.length === 0) return out;
  const rows = await db.tasks.bulkGet(candidateIds);
  const stored = await db.taskEvents.bulkGet(candidateIds.map(countsTowardEventId));
  const relevant = rows
    .map((task, i) => ({ task, existing: stored[i] }))
    .filter((c): c is { task: Task; existing: TaskEvent | undefined } =>
      c.task !== undefined && (c.task.countsTowardCounterId != null || c.existing !== undefined),
    );
  if (relevant.length === 0) return out;

  const taskById: Record<string, Task> = {};
  for (const t of await db.tasks.toArray()) taskById[t.id] = t;
  // Read inline (not via `buildWindowContext`): one fewer native-async hop
  // between Dexie requests keeps the caller's transaction zone alive.
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of await db.taskEvents.toArray()) if (!e.isDeleted) (eventsByTaskId[e.taskId] ??= []).push(e);
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of allChildren) (childrenByCompound[c.compoundTaskId] ??= []).push(c);

  const reach = new Map<string, string[]>();
  const noteReach = (rootId: string, occurredAt: string): void => {
    const list = reach.get(rootId) ?? [];
    if (!list.includes(occurredAt)) list.push(occurredAt);
    reach.set(rootId, list);
  };
  for (const { task, existing } of relevant) {
    const state = resolveContributionState(task, childrenByCompound, taskById, eventsByTaskId);
    const action = planCountsTowardAction(task, taskById, state, existing);
    if (!action) continue;
    await writeCountsTowardAction(action, task.userId, existing, now);
    noteReach(action.rootId, action.occurredAt);
    if (action.kind === 'revise') noteReach(action.previousRootId, action.previousOccurredAt);
  }

  for (const [rootId, instants] of reach) {
    const ids = await writeCounterRootLog(rootId, instants, now);
    if (ids.length === 0) continue;
    out.rootIds.add(rootId);
    for (const id of ids) out.cascadeIds.add(id);
    // Chained contributors: a compound containing one of these copies.
    const deeper = await writeCountsTowardForTasks(ids, now, undefined, depth + 1);
    for (const id of deeper.cascadeIds) out.cascadeIds.add(id);
    for (const id of deeper.rootIds) out.rootIds.add(id);
  }
  return out;
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
 * A counter root's events moved: a hand log's writes (`incrementSharedCounter`
 * / `undoLastCounterLog`) without the board cascade — restamp the root's
 * lifetime caches from events, refresh window-stamped baselines, write its
 * live copies, and name the frozen copies whose window holds a moved instant.
 *
 * @returns The root + copy ids to re-derive (`[]` for a deleted root).
 */
async function writeCounterRootLog(rootId: string, instants: string[], now: string): Promise<string[]> {
  const root = await db.tasks.get(rootId);
  if (!root || root.isDeleted) return [];
  await stampTaskCachesAuthored(rootId, now);
  await refreshDerivedBaselines(rootId);
  const after = await db.tasks.get(rootId);
  const [first, ...rest] = instants;
  const { linkedIds, reachedFrozenIds } = await writeLinkedRowPropagation(rootId, after?.currentCount ?? 0, now, first);
  const ids = new Set([rootId, ...linkedIds, ...reachedFrozenIds]);
  if (rest.length > 0) {
    const linked = await db.tasks.where('sharedCounterId').equals(rootId).filter((t) => !t.isDeleted).toArray();
    for (const t of linked) if (rest.some((at) => isFrozenRowReachedByEvent(t, at, now))) ids.add(t.id);
  }
  return [...ids];
}

/**
 * The cascade hook, FINISH phase — after the caller's board pass: re-derive
 * the sealed boards placing the roots' copies (a moved instant may sit inside
 * a closed window — the deterministic sealed re-derive) and refresh the
 * achievement watchers of every board reached.
 *
 * @param rootIds - {@link CountsTowardWrites.rootIds}.
 */
export async function finishCountsTowardRoots(rootIds: Set<string>): Promise<void> {
  if (rootIds.size === 0) return;
  await reDeriveSealedBoardsForTasks(rootIds);
  const watcherSeedIds = await resolveAffectedBoardIds(rootIds);
  if (watcherSeedIds.size > 0) await refreshWatchersForBoards(watcherSeedIds);
}

/**
 * The whole hook for a write path with no board cascade of its own (a
 * container created from already-done sub-tasks; a cascade delete): the
 * write phase, a board pass over what it touched, the finish phase.
 *
 * MUST run inside an `rw` transaction over the tables named above.
 *
 * @param taskIds - The tasks to re-derive.
 * @param now - The write instant.
 */
export async function applyCountsTowardInTransaction(taskIds: Iterable<string>, now: string): Promise<void> {
  const writes = await writeCountsTowardForTasks(taskIds, now);
  if (writes.cascadeIds.size > 0) await runBoardCascadeForTasks(writes.cascadeIds);
  await finishCountsTowardRoots(writes.rootIds);
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
 * {@link applyCountsTowardInTransaction} in its own transaction.
 *
 * @param taskIds - The tasks to re-derive.
 */
export async function syncCountsTowardFor(taskIds: string[]): Promise<void> {
  await db.transaction('rw', COUNTS_TOWARD_TABLES, () => applyCountsTowardInTransaction(taskIds, currentTimestamp()));
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
