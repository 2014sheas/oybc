import Dexie from 'dexie';
import { db } from '../internal';
import {
  COUNTS_TOWARD_PROBE_EVENT_LIMIT,
  SyncOperationType,
  buildForkChildrenIndex,
  canContribute,
  candidateContributionIds,
  countsTowardProblem,
  createForkEventResolver,
  creditActionReach,
  findTransitiveParentCompounds,
  forkLineageIds,
  isCreditWriteSealSuppressed,
  isFrozenRowReachedByEvent,
  keptCreditIdsFor,
  planCountsTowardActions,
  probeContributionIds,
  resolveContributionCredits,
  type Board,
  type CompoundChild,
  type ContributionInputs,
  type CountsTowardAction,
  type CountsTowardProblem,
  type SealImmuneWindow,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { getSealImmuneWindowsForTask, stampTaskCachesAuthored } from './taskEvents';
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
 *     reconcile its credit SET on its counter root — one credit per
 *     completion occurrence (D10), counted from `countsTowardSince` (D11),
 *     the fork lineage's wants protected, the counter's sealed windows
 *     honoured (D11): insert / revise / tombstone (version bump + enqueue) —
 *     then write the root's log like a hand log; the board pass derives the
 *     copies' boards, the finish phase re-derives sealed boards and refreshes
 *     watchers.
 *   - {@link setCountsToward} — the write-time entry that sets / clears the
 *     flag (validated by `countsTowardProblem`; stamps `countsTowardSince`).
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

const isDefined = <T>(x: T | undefined): x is T => x !== undefined;

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

/** Options for {@link writeCountsTowardForTasks}. */
export interface CountsTowardWriteOptions {
  /** The live compound links, when the caller already loaded them. */
  liveChildren?: CompoundChild[];
  /** `true` inside the closed-board late-log path (sealed windows are not a write barrier there — D11). */
  lateLog?: boolean;
  /** Chain depth (0 for a top-level call). */
  depth?: number;
}

/** The whole-workspace lookups loaded once a candidate is relevant. */
interface Workspace {
  taskById: Record<string, Task>;
  forkChildren: Record<string, string[]>;
  childrenByCompound: Record<string, CompoundChild[]>;
  allChildrenByCompound: Record<string, CompoundChild[]>;
  eventsByTaskId: Record<string, TaskEvent[]>;
  allEventsByTaskId: Record<string, TaskEvent[]>;
}

async function loadWorkspace(): Promise<Workspace> {
  const taskById: Record<string, Task> = {};
  const tasks = await db.tasks.toArray();
  for (const t of tasks) taskById[t.id] = t;
  // Read inline (not via `buildWindowContext`): one fewer native-async hop
  // between Dexie requests keeps the caller's transaction zone alive.
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  const allEventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of await db.taskEvents.toArray()) {
    (allEventsByTaskId[e.taskId] ??= []).push(e);
    if (!e.isDeleted) (eventsByTaskId[e.taskId] ??= []).push(e);
  }
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  const allChildrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of await db.compoundChildren.toArray()) {
    (allChildrenByCompound[c.compoundTaskId] ??= []).push(c);
    if (!c.isDeleted) (childrenByCompound[c.compoundTaskId] ??= []).push(c);
  }
  return { taskById, forkChildren: buildForkChildrenIndex(tasks), childrenByCompound, allChildrenByCompound, eventsByTaskId, allEventsByTaskId };
}

/** The most recent `limit` events (any state) of `taskId`, newest first — the unflagged-task probe's input. */
async function recentOwnEvents(taskId: string, limit: number): Promise<TaskEvent[]> {
  return db.taskEvents.where('[taskId+occurredAt]').between([taskId, Dexie.minKey], [taskId, Dexie.maxKey]).reverse().limit(limit).toArray();
}

/**
 * The cascade hook, WRITE phase (§3b). For every task in `changedTaskIds` and
 * every compound transitively containing one, reconcile its credit set and
 * apply each action (event row, version bump, enqueue); then, for each
 * counter root whose events moved, run a hand log's writes — restamp the
 * root's lifetime caches, refresh window-stamped baselines, propagate to its
 * live copies — and re-enter one level deeper for contributors that contain
 * those copies. Board derivation is left to the caller's ONE pass over
 * `cascadeIds` (so a copy on the contributor's own board is read with the new
 * increment and its bingo lands in that pass's result map);
 * {@link finishCountsTowardRoots} runs after it. Idempotent: a replay with no
 * state change writes nothing.
 *
 * Cost shape: rows that can never contribute (counter roots, linked copies,
 * achievements — `canContribute`) are dropped first. A FLAGGED candidate is
 * always relevant. An UNFLAGGED one is relevant only when a stored credit
 * exists at one of its PROBE ids (`probeContributionIds`: `lifetime`, a
 * `board` key per placement, the raw key of its most recent
 * `COUNTS_TOWARD_PROBE_EVENT_LIMIT` events — indexed reads, no lineage
 * walk); a cleared flag tombstones in the same transaction, so an unflagged
 * task holds credits only after an interrupted clear and the capped probe
 * is its self-heal. The whole-workspace loads, the fork lineage, the full
 * candidate keys and the per-root sealed windows are read only once a
 * candidate is relevant.
 *
 * MUST run inside the caller's `rw` transaction over `boards`, `boardTasks`,
 * `tasks`, `compoundChildren`, `taskEvents`, `syncQueue`.
 *
 * @param changedTaskIds - Tasks whose derived state may have changed.
 * @param now - The write instant (`createdAt` / `updatedAt` of written rows).
 * @param opts - See {@link CountsTowardWriteOptions}.
 * @returns The ids the caller's board pass must add, and the roots to finish.
 */
export async function writeCountsTowardForTasks(
  changedTaskIds: Iterable<string>,
  now: string,
  opts: CountsTowardWriteOptions = {},
): Promise<CountsTowardWrites> {
  const out: CountsTowardWrites = { cascadeIds: new Set(), rootIds: new Set() };
  const depth = opts.depth ?? 0;
  const lateLog = opts.lateLog === true;
  if (depth > MAX_COUNTS_TOWARD_DEPTH) {
    console.debug('[countsToward] chain depth cap reached; not re-entering', { depth, changedTaskIds: [...changedTaskIds] });
    return out;
  }
  const liveChildren = opts.liveChildren ?? (await db.compoundChildren.filter((c) => !c.isDeleted).toArray());
  const candidates = new Set<string>();
  for (const id of changedTaskIds) {
    candidates.add(id);
    for (const parent of findTransitiveParentCompounds(id, liveChildren)) candidates.add(parent);
  }
  if (candidates.size === 0) return out;
  const rows = (await db.tasks.bulkGet([...candidates])).filter(isDefined).filter(canContribute);
  if (rows.length === 0) return out;

  // Phase 1 — relevance. Flagged rows are relevant; unflagged rows only when
  // a stored credit sits at one of their probe ids.
  const storedById: Record<string, TaskEvent | undefined> = {};
  const unflagged = rows.filter((t) => t.countsTowardCounterId == null);
  const relevant = rows.filter((t) => t.countsTowardCounterId != null);
  if (unflagged.length > 0) {
    const placements = await db.boardTasks.where('taskId').anyOf(unflagged.map((t) => t.id)).toArray();
    const probeIdsByTask = new Map<string, string[]>();
    for (const t of unflagged) {
      probeIdsByTask.set(t.id, probeContributionIds(t, await recentOwnEvents(t.id, COUNTS_TOWARD_PROBE_EVENT_LIMIT), placements));
    }
    for (const e of (await db.taskEvents.bulkGet([...new Set([...probeIdsByTask.values()].flat())])).filter(isDefined)) storedById[e.id] = e;
    for (const t of unflagged) if ((probeIdsByTask.get(t.id) ?? []).some((id) => storedById[id] !== undefined)) relevant.push(t);
  }
  if (relevant.length === 0) return out;

  // Phase 2 — the workspace, the lineage, the full keys.
  const ws = await loadWorkspace();
  const resolver = createForkEventResolver(ws.taskById, ws.allEventsByTaskId);
  const lineageByTask = new Map(relevant.map((t) => [t.id, forkLineageIds(t.id, ws.taskById, ws.forkChildren)]));
  const memberIds = new Set<string>([...relevant.map((t) => t.id), ...[...lineageByTask.values()].flat()]);
  const placements = await db.boardTasks.where('taskId').anyOf([...memberIds]).toArray();
  const boardById: Record<string, Board> = {};
  for (const b of (await db.boards.bulkGet([...new Set(placements.map((p) => p.boardId))])).filter(isDefined)) boardById[b.id] = b;
  const inputsFor = (task: Task): ContributionInputs => ({
    taskById: ws.taskById,
    childrenByCompound: ws.childrenByCompound,
    allChildrenByCompound: ws.allChildrenByCompound,
    eventsByTaskId: ws.eventsByTaskId,
    allEventsByTaskId: ws.allEventsByTaskId,
    placements: placements.filter((p) => p.taskId === task.id),
    boardById,
    forkEvents: resolver,
  });
  const keptByMember = new Map<string, string[]>();
  const keptFor = (memberId: string): string[] => {
    let kept = keptByMember.get(memberId);
    if (!kept) {
      const member = ws.taskById[memberId];
      kept = member ? keptCreditIdsFor(member, inputsFor(member)) : [];
      keptByMember.set(memberId, kept);
    }
    return kept;
  };
  const immuneByRoot: Record<string, ReadonlyArray<SealImmuneWindow>> = {};
  const immuneFor = async (rootId: string): Promise<ReadonlyArray<SealImmuneWindow>> => {
    if (!(rootId in immuneByRoot)) immuneByRoot[rootId] = await getSealImmuneWindowsForTask(rootId);
    return immuneByRoot[rootId];
  };

  const reach = new Map<string, string[]>();
  const noteReach = (rootId: string, occurredAt: string): void => {
    const list = reach.get(rootId) ?? [];
    if (!list.includes(occurredAt)) list.push(occurredAt);
    reach.set(rootId, list);
  };
  for (const task of relevant) {
    const inputs = inputsFor(task);
    const wanted = resolveContributionCredits(task, inputs);
    const candidateIds = candidateContributionIds(task, inputs);
    const lineageWanted = new Set((lineageByTask.get(task.id) ?? []).flatMap(keptFor));
    const missing = [...new Set([...candidateIds, ...wanted.map((w) => w.eventId)])].filter((id) => !(id in storedById));
    for (const id of missing) storedById[id] = undefined;
    for (const e of (await db.taskEvents.bulkGet(missing)).filter(isDefined)) storedById[e.id] = e;
    for (const action of planCountsTowardActions(task, ws.taskById, wanted, candidateIds, storedById, lineageWanted)) {
      if (!lateLog) for (const { rootId } of creditActionReach(action)) await immuneFor(rootId);
      if (isCreditWriteSealSuppressed(action, immuneByRoot, now, lateLog)) continue;
      await writeCountsTowardAction(action, task.userId, storedById[action.eventId], now);
      for (const { rootId, occurredAt } of creditActionReach(action)) noteReach(rootId, occurredAt);
    }
  }

  for (const [rootId, instants] of reach) {
    const ids = await writeCounterRootLog(rootId, instants, now);
    if (ids.length === 0) continue;
    out.rootIds.add(rootId);
    for (const id of ids) out.cascadeIds.add(id);
    // Chained contributors: a compound containing one of these copies.
    const deeper = await writeCountsTowardForTasks(ids, now, { lateLog, depth: depth + 1 });
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
  // A revive drops `deletedAt`; `taskEvents.deletedAt` is clearable on sync so
  // the stale stamp leaves the remote doc too.
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
 * its cascade so the credits follow at once. D11: setting the flag, or
 * re-pointing it at a DIFFERENT counter, stamps `countsTowardSince = now`
 * (occurrences before it never credit); changing only the amount keeps it;
 * a clear removes all three fields (clearable on sync). Authored: version
 * bump + UPDATE enqueue.
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
    const since = counterId == null ? undefined : counterId === task.countsTowardCounterId && task.countsTowardSince != null ? task.countsTowardSince : now;
    const { countsTowardCounterId: _id, countsTowardAmount: _amount, countsTowardSince: _since, ...rest } = task;
    const next: Task = {
      ...rest,
      ...(counterId != null ? { countsTowardCounterId: counterId, countsTowardSince: since } : {}),
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
 * Clear the counts-toward fields on every live contributor of a counter that
 * is being deleted (§3e). Authored: version bump + UPDATE enqueue; the events
 * stay with the (deleted) root. Must run inside the delete's transaction.
 *
 * @param counterId - The counter root being deleted.
 * @param now - The delete instant.
 */
export async function unflagContributorsOf(counterId: string, now: string): Promise<void> {
  for (const c of await countContributorsOf(counterId)) {
    const { countsTowardCounterId: _id, countsTowardAmount: _amount, countsTowardSince: _since, ...rest } = c;
    const next: Task = { ...rest, updatedAt: now, version: c.version + 1 };
    await db.tasks.put(next);
    await addToSyncQueue('tasks', c.id, SyncOperationType.UPDATE, next);
  }
}
