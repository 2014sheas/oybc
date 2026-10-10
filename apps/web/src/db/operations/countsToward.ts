import { db } from '../internal';
import {
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
  lineageCreditDelta,
  lineageRootId,
  planCountsTowardActions,
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
import { writeLinkedRowPropagation, type AffectedBoard } from './tasks.sharedCounter';
import { isBoardCreditable } from '../../utils/boardDisplayUtils';
import { healBoardNames } from './boardNames';
import { reDeriveSealedBoardsForTasks } from './sealing';
import { refreshWatchersForBoards, resolveAffectedBoardIds } from './boardLifecycle';
import { runBoardCascadeForTasks } from './orchestration';

/**
 * countsToward.ts — "counts toward", web data half
 * (docs/SHARED_COUNTER_SETTINGS.md §3b). Swift twin:
 * `AppDatabase+CountsToward.swift`. The pure rules live in `@oybc/shared`
 * (`countsToward.ts` + `countsTowardLineage.ts`); this module writes them.
 *
 *   - {@link writeCountsTowardForTasks} / {@link finishCountsTowardRoots} —
 *     the cascade hook, wrapped around the board pass of every
 *     `runBoardCascadeForTasks` (the one choke point every local write, the
 *     pull paths and the late-log re-derivation go through), inside the same
 *     transaction: for each changed task and each compound containing it,
 *     reconcile its credit SET on its counter root — one credit per
 *     completion occurrence (D10), counted from `countsTowardSince` (D11),
 *     keyed on the target root, the fork lineage's wants protected and its
 *     amount agreed, the counter's sealed windows honoured (D11): insert /
 *     revise / tombstone (version bump + enqueue) — then write the root's
 *     log like a hand log; the board pass derives the copies' boards, the
 *     finish phase re-derives sealed boards and refreshes watchers.
 *   - {@link setCountsToward} — the write-time entry that sets / clears the
 *     flag (validated by `countsTowardProblem`; stamps `countsTowardSince`;
 *     hands the previous root to the cascade so its credits are withdrawn).
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
  /**
   * Inside the closed-board late-log path: the instant that path stamped
   * (the closed board's `endDate`). Only a credit at that exact instant is
   * exempt from the counter's sealed windows (D11).
   */
  lateLogStamp?: string | null;
  /**
   * Counter roots the named tasks counted toward BEFORE this write (a
   * re-point / clear, a pulled row that was flagged) — their credits on those
   * roots are reconciled too.
   */
  previousRootsByTask?: Record<string, string>;
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
 * Relevance: rows that can never contribute (counter roots, linked copies,
 * achievements — `canContribute`) are dropped first; a FLAGGED row is
 * relevant, and so is a row whose previous root the caller knows
 * (`previousRootsByTask`). Every credit key carries its root, so an unflagged
 * row with no known previous root has nothing derivable to reconcile — the
 * write paths that clear or re-point a flag (`setCountsToward`, the pull of a
 * row that was flagged) pass that root explicitly. The whole-workspace loads,
 * the fork lineage, the candidate keys and the per-root sealed windows are
 * read only once a candidate is relevant.
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
  const lateLogStamp = opts.lateLogStamp ?? null;
  const previousRoots = opts.previousRootsByTask ?? {};
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
  const relevant = rows.filter((t) => t.countsTowardCounterId != null || previousRoots[t.id] != null);
  if (relevant.length === 0) return out;

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
  // Per-root seal-immune windows, cached for the cascade. Looked up INLINE
  // below (not through an async helper): a second native-promise hop around a
  // Dexie read loses Dexie's transaction zone, and the credit writes would
  // then run outside the caller's transaction.
  const immuneByRoot: Record<string, ReadonlyArray<SealImmuneWindow>> = {};
  const storedById: Record<string, TaskEvent | undefined> = {};

  const reach = new Map<string, string[]>();
  const noteReach = (rootId: string, occurredAt: string): void => {
    const list = reach.get(rootId) ?? [];
    if (!list.includes(occurredAt)) list.push(occurredAt);
    reach.set(rootId, list);
  };
  for (const task of relevant) {
    const inputs = inputsFor(task);
    const members = [task, ...(lineageByTask.get(task.id) ?? []).map((id) => ws.taskById[id]).filter(isDefined)];
    // Every root the lineage currently targets, plus the one the caller knows
    // this task targeted before — the keys a stale credit can sit under.
    const candidateRoots = [
      ...new Set([...members.map((m) => m.countsTowardCounterId).filter((r): r is string => r != null), ...(previousRoots[task.id] ? [previousRoots[task.id]] : [])]),
    ];
    const wanted = resolveContributionCredits(task, inputs);
    const candidateIds = candidateContributionIds(task, inputs, candidateRoots);
    const lineageWanted = new Set((lineageByTask.get(task.id) ?? []).flatMap(keptFor));
    const lineageRoot = lineageRootId(task, ws.taskById);
    const missing = [...new Set([...candidateIds, ...wanted.map((w) => w.eventId)])].filter((id) => !(id in storedById));
    for (const id of missing) storedById[id] = undefined;
    for (const e of (await db.taskEvents.bulkGet(missing)).filter(isDefined)) storedById[e.id] = e;
    const actions = planCountsTowardActions(task, ws.taskById, wanted, candidateIds, storedById, {
      wantedIds: lineageWanted,
      deltaForRoot: (rootId) => lineageCreditDelta(rootId, members, lineageRoot),
    });
    for (const action of actions) {
      for (const { rootId } of creditActionReach(action)) {
        if (!(rootId in immuneByRoot)) immuneByRoot[rootId] = await getSealImmuneWindowsForTask(rootId);
      }
      if (isCreditWriteSealSuppressed(action, immuneByRoot, now, lateLogStamp)) continue;
      await writeCountsTowardAction(action, task.userId, storedById[action.eventId], now);
      storedById[action.eventId] = await db.taskEvents.get(action.eventId);
      for (const { rootId, occurredAt } of creditActionReach(action)) noteReach(rootId, occurredAt);
    }
  }

  for (const [rootId, instants] of reach) {
    const ids = await writeCounterRootLog(rootId, instants, now);
    if (ids.length === 0) continue;
    out.rootIds.add(rootId);
    for (const id of ids) out.cascadeIds.add(id);
    // Chained contributors: a compound containing one of these copies.
    const deeper = await writeCountsTowardForTasks(ids, now, { lateLogStamp, depth: depth + 1 });
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
 * a clear removes all three fields (clearable on sync). The previous root is
 * handed to the cascade so the credits keyed on it are withdrawn (a re-point
 * is a tombstone on the old root + an insert on the new one). Authored:
 * version bump + UPDATE enqueue.
 *
 * @param taskId - The contributing task.
 * @param counterId - The Discrete counter root, or `null` to stop counting.
 * @param amount - Increment per completion (absent = 1).
 * @throws {CountsTowardError} with the `countsTowardProblem` code when refused.
 */
export async function setCountsToward(taskId: string, counterId: string | null, amount?: number): Promise<void> {
  await db.transaction('rw', COUNTS_TOWARD_TABLES, () => setCountsTowardInTransaction(taskId, counterId, amount, currentTimestamp()));
}

/**
 * {@link setCountsToward}'s body, for callers already inside a transaction
 * covering `COUNTS_TOWARD_TABLES` (Board Edit's commit flags the FORK after
 * `ensureBoardScopedTask`; the task-edit save runs it beside its other
 * writes). The ONE write path for the flag — nothing else may write
 * `countsTowardCounterId`.
 *
 * @param taskId - The contributing task.
 * @param counterId - The Discrete counter root, or `null` to stop counting.
 * @param amount - Increment per completion (absent = 1).
 * @param now - The write instant (stamps `countsTowardSince` on a set / re-point).
 * @throws {CountsTowardError} with the `countsTowardProblem` code when refused.
 */
export async function setCountsTowardInTransaction(taskId: string, counterId: string | null, amount: number | undefined, now: string): Promise<void> {
  {
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
    const previousRoot = task.countsTowardCounterId ?? null;
    const since = counterId == null ? undefined : counterId === previousRoot && task.countsTowardSince != null ? task.countsTowardSince : now;
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
    await runBoardCascadeForTasks([taskId], previousRoot != null && previousRoot !== counterId ? { countsTowardPreviousRoots: { [taskId]: previousRoot } } : {});
  }
}

/**
 * The boards a counts-toward credit on `rootId` lands on, for the credited
 * toast ("+1 Books — also counted on …"): the ACTIVE, creditable boards
 * (`isBoardCreditable` — not sealed, window not ended) placing the counter
 * root or any live linked copy, minus `excludeBoardId` (the board the
 * completion was made on). Same board set the shared-counter increment path
 * credits.
 *
 * @param rootId - The counter root.
 * @param excludeBoardId - The completing board (never listed).
 * @param now - The clock the creditable check uses.
 */
export async function creditedBoardsForCounter(rootId: string, excludeBoardId: string | null, now: Date): Promise<AffectedBoard[]> {
  const copies = await db.tasks.filter((t) => !t.isDeleted && t.sharedCounterId === rootId).toArray();
  const ids = [rootId, ...copies.map((c) => c.id)];
  const placements = await db.boardTasks.where('taskId').anyOf(ids).filter((bt) => !bt.isDeleted).toArray();
  const boardIds = [...new Set(placements.map((p) => p.boardId))].filter((id) => id !== excludeBoardId);
  if (boardIds.length === 0) return [];
  const boards = healBoardNames(await db.boards.where('id').anyOf(boardIds).toArray());
  return boards.filter((b) => isBoardCreditable(b, now)).map((b) => ({ boardId: b.id, boardName: b.name }));
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
