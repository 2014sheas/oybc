import {
  SyncOperationType,
  TaskType,
  finalizeWindowCount,
  generateCounterTaskTitle,
  isAutoCounterTitle,
  isWholeCountKind,
  planCountKindSwitch,
  quantizeCount,
  resolveCountKind,
  type CountKind,
  type CounterTitleSettings,
  type Task,
} from '@oybc/shared';
import { db } from '../internal';
import { addToSyncQueue } from './syncQueue';
import { runBoardCascadeForTasks } from './orchestration';
import { reDeriveSealedBoardsForTasks } from './sealing';
import { computeTaskCachesFromEvents } from './taskEvents';
import { countContributorsOf } from './countsToward';
import { loadLiveSealedBoardIds, loadReachedBoardIdsByTask, taskIdsReachingSealedBoards } from './placementReach';

/**
 * countKindSwitch.ts — counter kinds, web half of the family-wide kind rules
 * (docs/COUNTER_KINDS.md D4/D5). Swift twin: `AppDatabase+CountKindSwitch.swift`.
 *
 *  - {@link switchCounterKind} — switch a counter ROOT between `discrete`
 *    and `continuous`, cascading to its live family.
 *  - {@link withRootCountKind} — the write-time rule that a new linked row
 *    carries its root's kind.
 */

/** Why {@link switchCounterKind} refused. */
export type CountKindSwitchErrorCode = 'not-a-root' | 'refused' | 'not-counting' | 'has-contributors';

/**
 * Refusal line when a counter other tasks count toward would leave Discrete
 * (docs/SHARED_COUNTER_SETTINGS.md D9; iOS `CountKindSwitch.countsTowardMessage`).
 */
export const COUNTS_TOWARD_KIND_MESSAGE = 'A counter other tasks count toward stays Discrete.';

/** Thrown by {@link switchCounterKind}; nothing is written when it is. */
export class CountKindSwitchError extends Error {
  /** The refusal reason. */
  readonly code: CountKindSwitchErrorCode;

  /**
   * @param code - The refusal reason.
   * @param message - Developer-facing detail.
   */
  constructor(code: CountKindSwitchErrorCode, message: string) {
    super(message);
    this.name = 'CountKindSwitchError';
    this.code = code;
  }
}

/**
 * Switch a counter root's kind and cascade it to the root's family, in ONE
 * transaction.
 *
 * Writes `countKind = to` (always explicit — the field is never cleared) plus
 * the `planCountKindSwitch` goal / default-amount rounding on the root and on
 * every row {@link familyRowsToSwitch} returns (live linked rows no sealed
 * board holds — a closed board's copy keeps its kind and goal until Reopen
 * re-aligns it, the same exclusion as root → copy propagation), each with a
 * version bump + UPDATE enqueue. Then the board cascade re-derives every live
 * board placing a written row and the sealed re-derive every closed one
 * placing the root (a placement's frozen `targetKind` keeps its goal's kind).
 * `taskEvents` are never touched: a whole kind rounds the window SUM at read
 * time, so switching back restores the exact fractional count. The root's
 * lifetime caches (`isCompleted` / `currentCount` / `completedAt` /
 * `totalCompletions`) are recomputed from events in the same write
 * (`computeTaskCachesFromEvents`); a linked row's caches are never read (it
 * resolves from the root's events) and are not written.
 *
 * @param rootTaskId - The counter root (a COUNTING task with no `sharedCounterId`).
 * @param to - The requested kind.
 * @param now - The switch instant. Defaults to now.
 * @throws {CountKindSwitchError} `not-counting` when the id is not a live
 *   COUNTING task; `not-a-root` for a linked row (only roots switch);
 *   `refused` when the root cannot move from its kind to `to` (duration
 *   either way, or no change); `has-contributors` when leaving Discrete while
 *   tasks count toward the counter (D9).
 */
export async function switchCounterKind(
  rootTaskId: string,
  to: CountKind,
  now: Date = new Date(),
): Promise<void> {
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    () => switchCounterKindInTransaction(rootTaskId, to, now.toISOString()),
  );
}

/**
 * {@link switchCounterKind}'s body, for a caller that already holds an `rw`
 * transaction over `boards, boardTasks, tasks, compoundChildren, taskEvents,
 * syncQueue` (editing saves fold the switch into their own write).
 *
 * @param rootTaskId - The counter root.
 * @param to - The requested kind.
 * @param nowIso - The switch instant, ISO8601.
 * @returns The ids written (root first, then each live family row).
 * @throws {CountKindSwitchError} as {@link switchCounterKind}.
 */
export async function switchCounterKindInTransaction(
  rootTaskId: string,
  to: CountKind,
  nowIso: string,
): Promise<string[]> {
  const root = await db.tasks.get(rootTaskId);
  if (!root || root.isDeleted || root.type !== TaskType.COUNTING) {
    throw new CountKindSwitchError('not-counting', `switchCounterKind: ${rootTaskId} is not a live counting task`);
  }
  if (root.sharedCounterId != null) {
    throw new CountKindSwitchError('not-a-root', `switchCounterKind: ${rootTaskId} is a linked row; switch its root`);
  }
  const rootPatch = planCountKindSwitch(root, resolveCountKind(root), to);
  if (!rootPatch) {
    throw new CountKindSwitchError(
      'refused',
      `switchCounterKind: ${resolveCountKind(root)} → ${to} is not a permitted switch`,
    );
  }
  // D9 — "counts toward" targets Discrete counters only; leaving Discrete
  // while contributors exist is refused (the message is the user-facing line).
  if (to !== 'discrete' && (await countContributorsOf(root.id)).length > 0) {
    throw new CountKindSwitchError('has-contributors', COUNTS_TOWARD_KIND_MESSAGE);
  }
  const rootEvents = await db.taskEvents.where('taskId').equals(root.id).toArray();
  const rootCaches = computeTaskCachesFromEvents({ ...root, ...rootPatch, countKind: to }, rootEvents);
  await writeKindSwitch(root, to, { ...rootPatch, ...rootCaches }, nowIso);
  const writtenIds = [root.id];

  for (const { row, patch } of await familyRowsToSwitch(root.id, to)) {
    await writeKindSwitch(row, to, patch, nowIso);
    writtenIds.push(row.id);
  }

  await runBoardCascadeForTasks(writtenIds);
  // A root placed on a CLOSED board re-derives deterministically (the
  // sanctioned sealed path — the live cascade skips it). No written copy is on
  // one: `familyRowsToSwitch` leaves those untouched.
  await reDeriveSealedBoardsForTasks(writtenIds);
  return writtenIds;
}

/** A linked row a kind write moves, with its `planCountKindSwitch` patch. */
interface KindRowWrite {
  row: Task;
  patch: Partial<Task>;
}

/**
 * The linked rows a kind switch of `rootId` to `to` writes, each with its
 * `planCountKindSwitch` patch: live rows linked to the root whose kind
 * actually moves, minus any a sealed board holds — directly or as a
 * sub-task of a compound placed there (issue #576 item 2; the exclusion
 * `planRootFieldPropagation` applies, via the same
 * `taskIdsReachingSealedBoards`). Shared by the switch and its preview so the
 * confirm's count is exactly the rows written. Runs inside the caller's
 * transaction (or a read).
 *
 * @param rootId - The counter root.
 * @param to - The requested kind.
 * @returns The rows to write, in index order.
 */
async function familyRowsToSwitch(rootId: string, to: CountKind): Promise<KindRowWrite[]> {
  const family = await db.tasks
    .where('sharedCounterId')
    .equals(rootId)
    .filter((t) => !t.isDeleted)
    .toArray();
  const moving: KindRowWrite[] = [];
  for (const row of family) {
    const patch = planCountKindSwitch(row, resolveCountKind(row), to);
    if (patch) moving.push({ row, patch }); // else already `to` (or a kind that never switches)
  }
  const sealed = await taskIdsReachingSealedBoards(moving.map((m) => m.row.id));
  return moving.filter((m) => !sealed.has(m.row.id)); // a closed board's record
}

/**
 * Reopen's kind re-alignment (docs/COUNTER_KINDS.md D5): a linked row's kind
 * mirrors its root's except while a sealed board holds it. When Reopen frees
 * `boardId`, every live linked COUNTING row that board reaches (directly or
 * through a placed compound) whose kind differs from its root's — and that no
 * OTHER sealed board still holds — takes the root's kind through
 * `planCountKindSwitch`, as the kind switch would have written it: one
 * authored write each (version bump + UPDATE enqueue).
 *
 * Must run inside Reopen's `rw` transaction, AFTER the seal is cleared. It
 * does not cascade: the caller re-derives the boards the returned rows reach.
 *
 * @param boardId - The board just reopened.
 * @param nowIso - ISO8601 write time.
 * @returns The ids of the rows re-aligned.
 */
export async function realignLinkedKindsOnReopen(boardId: string, nowIso: string): Promise<string[]> {
  const linked = await db.tasks
    .filter((t) => !t.isDeleted && t.type === TaskType.COUNTING && t.sharedCounterId != null)
    .toArray();
  const rootIds = [...new Set(linked.map((t) => t.sharedCounterId as string))];
  const roots = new Map<string, Task>();
  for (const r of await db.tasks.bulkGet(rootIds)) {
    if (r && !r.isDeleted && r.type === TaskType.COUNTING) roots.set(r.id, r);
  }
  const drifted: Array<KindRowWrite & { to: CountKind }> = [];
  for (const row of linked) {
    const root = roots.get(row.sharedCounterId as string);
    if (!root) continue;
    const to = resolveCountKind(root);
    const patch = planCountKindSwitch(row, resolveCountKind(row), to);
    if (patch) drifted.push({ row, patch, to });
  }
  if (drifted.length === 0) return [];

  const reach = await loadReachedBoardIdsByTask(drifted.map((d) => d.row.id));
  const sealed = await loadLiveSealedBoardIds();
  const written: string[] = [];
  for (const { row, patch, to } of drifted) {
    const boards = reach.get(row.id) ?? new Set<string>();
    if (!boards.has(boardId) || [...boards].some((b) => sealed.has(b))) continue;
    await writeKindSwitch(row, to, patch, nowIso);
    written.push(row.id);
  }
  return written;
}

/** A whole kind received a fractional goal (D4) — the caller's transaction rolls back. */
export class KindGoalError extends Error {
  constructor() {
    super('Whole-number kinds need whole goals');
    this.name = 'KindGoalError';
  }
}

/**
 * The ONE "switch if changed, then guard the goal" step every editing save
 * runs inside its own transaction (Task Detail, Board Edit, staged pool /
 * wizard edits — Ruling U7).
 *
 * @param taskId - The edited task.
 * @param to - The kind the editor chose; undefined = unchanged.
 * @param maxCount - The goal the caller is about to write, if any.
 * @param nowIso - Switch instant.
 * @returns True when a switch was written.
 * @throws {KindGoalError} when `maxCount` is fractional at a whole final kind.
 */
export async function applyKindSwitchThenGoalGuard(
  taskId: string,
  to: CountKind | undefined,
  maxCount: number | null | undefined,
  nowIso: string,
): Promise<boolean> {
  const task = await db.tasks.get(taskId);
  if (!task || task.isDeleted || task.type !== TaskType.COUNTING) return false;
  const from = resolveCountKind(task);
  let switched = false;
  if (to !== undefined && to !== from && task.sharedCounterId == null) {
    await switchCounterKindInTransaction(taskId, to, nowIso);
    switched = true;
  }
  const finalKind = switched && to !== undefined ? to : from;
  if (maxCount != null && isWholeCountKind(finalKind) && !Number.isInteger(maxCount)) throw new KindGoalError();
  return switched;
}

/** What the Continuous → Discrete confirm shows (docs/COUNTER_KINDS.md §5). */
export interface KindSwitchPreview {
  from: CountKind;
  to: CountKind;
  titleBefore: string;
  titleAfter: string;
  loggedBefore: number;
  loggedAfter: number;
  linkedCount: number;
}

/**
 * Pure preview from a task's own fields (pending tasks use it directly).
 *
 * The title is judged and re-rendered through the counter ROOT's templates
 * (docs/SHARED_COUNTER_SETTINGS.md §1b): `settings` defaults to the task's own
 * (a root), and a caller previewing a linked copy passes its root's.
 *
 * @param task - The task (or editor draft) being switched.
 * @param to - The requested kind.
 * @param linkedCount - Live family rows the switch would also write.
 * @param settings - The root's name + templates (defaults to `task`'s own).
 * @returns The preview, or null when the switch is refused.
 */
export function planKindSwitchPreview(
  task: Pick<Task, 'title' | 'action' | 'unit' | 'maxCount' | 'currentCount' | 'countKind'> & CounterTitleSettings,
  to: CountKind,
  linkedCount: number,
  settings: CounterTitleSettings | null = task,
): KindSwitchPreview | null {
  const from = resolveCountKind(task);
  const patch = planCountKindSwitch(task, from, to);
  if (!patch) return null;
  const action = task.action ?? '';
  const unit = task.unit ?? '';
  const auto = isAutoCounterTitle(task.title, action, task.maxCount, unit, from, settings);
  const loggedBefore = quantizeCount(task.currentCount ?? 0);
  return {
    from,
    to,
    titleBefore: task.title,
    titleAfter: auto
      ? generateCounterTaskTitle(action, patch.maxCount ?? task.maxCount, unit, undefined, to, settings)
      : task.title,
    loggedBefore,
    loggedAfter: finalizeWindowCount(loggedBefore, to),
    linkedCount,
  };
}

/**
 * Read-only preview of {@link switchCounterKind} for a stored root.
 *
 * @param rootTaskId - The counter root.
 * @param to - The requested kind.
 * @returns The preview, or null for a missing / non-counting / linked task
 *   or a refused switch.
 */
export async function previewCounterKindSwitch(
  rootTaskId: string,
  to: CountKind,
): Promise<KindSwitchPreview | null> {
  const root = await db.tasks.get(rootTaskId);
  if (!root || root.isDeleted || root.type !== TaskType.COUNTING || root.sharedCounterId != null) return null;
  // Exactly the rows switchCounterKindInTransaction would write.
  const linkedCount = (await familyRowsToSwitch(root.id, to)).length;
  return planKindSwitchPreview(root, to, linkedCount);
}

/**
 * One authored kind-switch write: kind + rounded fields, version bump, UPDATE
 * enqueue. Must run inside the caller's `rw` transaction.
 *
 * @param task - The row as read in this transaction.
 * @param to - The new kind.
 * @param patch - `planCountKindSwitch` output for this row.
 * @param nowIso - ISO8601 `updatedAt`.
 */
async function writeKindSwitch(
  task: Task,
  to: CountKind,
  patch: Partial<Task>,
  nowIso: string,
): Promise<void> {
  await db.tasks.update(task.id, {
    ...patch,
    countKind: to,
    updatedAt: nowIso,
    version: (task.version ?? 0) + 1,
  });
  const saved = await db.tasks.get(task.id);
  // The row was read in this transaction; a miss means the write did not land.
  if (!saved) throw new Error(`switchCounterKind: ${task.id} vanished mid-transaction`);
  await addToSyncQueue('tasks', task.id, SyncOperationType.UPDATE, saved, 0);
}

/**
 * The write-time family rule (D5): a new LINKED counting row carries its
 * root's kind. Returns `task` unchanged for anything else, or when the root
 * cannot be read. Call it inside the write transaction that inserts `task`
 * (it reads `db.tasks`).
 *
 * @param task - The row about to be inserted.
 * @returns The row with the root's `countKind` copied onto it.
 */
export async function withRootCountKind(task: Task): Promise<Task> {
  if (task.type !== TaskType.COUNTING || !task.sharedCounterId) return task;
  const root = await db.tasks.get(task.sharedCounterId);
  if (!root || root.countKind === task.countKind) return task;
  // An absent root kind is discrete: the copy stays absent too.
  const copy: Task = { ...task };
  if (root.countKind) copy.countKind = root.countKind;
  else delete copy.countKind;
  return copy;
}
