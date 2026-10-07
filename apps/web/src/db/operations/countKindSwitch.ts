import {
  SyncOperationType,
  TaskType,
  finalizeWindowCount,
  generateCounterTaskTitle,
  isAutoCounterTitle,
  isFrozenDerivedRow,
  isWholeCountKind,
  planCountKindSwitch,
  propagateIncrement,
  quantizeCount,
  resolveCountKind,
  type CountKind,
  type Task,
} from '@oybc/shared';
import { db } from '../internal';
import { addToSyncQueue } from './syncQueue';
import { runBoardCascadeForTasks } from './orchestration';
import { computeTaskCachesFromEvents } from './taskEvents';

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
export type CountKindSwitchErrorCode = 'not-a-root' | 'refused' | 'not-counting';

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
 * every live row whose `sharedCounterId` is the root, each with a version
 * bump + UPDATE enqueue. A window-stamped derived row whose window has ended
 * (`isFrozenDerivedRow`) is a permanent record and keeps its kind and goal.
 * Then the board cascade re-derives every board placing a written row.
 * `taskEvents` are never touched: a whole kind rounds the window SUM at read
 * time, so switching back restores the exact fractional count. The lifetime
 * caches (`isCompleted` / `currentCount` / `completedAt`) are recomputed from
 * events in the same write — the root via `computeTaskCachesFromEvents`, each
 * linked row via `propagateIncrement` from the root's new count (the same
 * rules the event-append path uses) — so the library / Task Detail / hub
 * agree with the board grids on the new kind.
 *
 * @param rootTaskId - The counter root (a COUNTING task with no `sharedCounterId`).
 * @param to - The requested kind.
 * @param now - The switch instant (also the freeze clock). Defaults to now.
 * @throws {CountKindSwitchError} `not-counting` when the id is not a live
 *   COUNTING task; `not-a-root` for a linked row (only roots switch);
 *   `refused` when the root cannot move from its kind to `to` (duration
 *   either way, or no change).
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
 * @param nowIso - The switch instant (also the freeze clock), ISO8601.
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
  const rootEvents = await db.taskEvents.where('taskId').equals(root.id).toArray();
  const rootCaches = computeTaskCachesFromEvents({ ...root, ...rootPatch, countKind: to }, rootEvents);
  await writeKindSwitch(root, to, { ...rootPatch, ...rootCaches }, nowIso);
  const writtenIds = [root.id];

  const family = await db.tasks
    .where('sharedCounterId')
    .equals(root.id)
    .filter((t) => !t.isDeleted)
    .toArray();
  for (const row of family) {
    if (isFrozenDerivedRow(row, nowIso)) continue;
    const rowPatch = planCountKindSwitch(row, resolveCountKind(row), to);
    if (!rowPatch) continue; // already `to` (or a kind that never switches)
    const [derived] = propagateIncrement({ currentCount: rootCaches.currentCount ?? 0 }, [
      {
        id: row.id,
        baseline: row.baseline,
        maxCount: rowPatch.maxCount ?? row.maxCount,
        isCompleted: row.isCompleted,
        countKind: to,
      },
    ]);
    await writeKindSwitch(
      row,
      to,
      {
        ...rowPatch,
        currentCount: derived.newCurrentCount,
        isCompleted: derived.newIsCompleted,
        completedAt: !row.isCompleted && derived.newIsCompleted ? nowIso : row.completedAt,
      },
      nowIso,
    );
    writtenIds.push(row.id);
  }

  await runBoardCascadeForTasks(writtenIds);
  return writtenIds;
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
 * @param nowIso - Switch instant / freeze clock.
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
 * @param task - The task (or editor draft) being switched.
 * @param to - The requested kind.
 * @param linkedCount - Live family rows the switch would also write.
 * @returns The preview, or null when the switch is refused.
 */
export function planKindSwitchPreview(
  task: Pick<Task, 'title' | 'action' | 'unit' | 'maxCount' | 'currentCount' | 'countKind'>,
  to: CountKind,
  linkedCount: number,
): KindSwitchPreview | null {
  const from = resolveCountKind(task);
  const patch = planCountKindSwitch(task, from, to);
  if (!patch) return null;
  const action = task.action ?? '';
  const unit = task.unit ?? '';
  const auto = isAutoCounterTitle(task.title, action, task.maxCount, unit, from);
  const loggedBefore = quantizeCount(task.currentCount ?? 0);
  return {
    from,
    to,
    titleBefore: task.title,
    titleAfter: auto ? generateCounterTaskTitle(action, patch.maxCount ?? task.maxCount, unit, undefined, to) : task.title,
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
 * @param now - Freeze clock for the family count. Defaults to now.
 * @returns The preview, or null for a missing / non-counting / linked task
 *   or a refused switch.
 */
export async function previewCounterKindSwitch(
  rootTaskId: string,
  to: CountKind,
  now: Date = new Date(),
): Promise<KindSwitchPreview | null> {
  const root = await db.tasks.get(rootTaskId);
  if (!root || root.isDeleted || root.type !== TaskType.COUNTING || root.sharedCounterId != null) return null;
  const nowIso = now.toISOString();
  const family = await db.tasks
    .where('sharedCounterId')
    .equals(root.id)
    .filter((t) => !t.isDeleted)
    .toArray();
  // Exactly the rows switchCounterKindInTransaction would write.
  const linkedCount = family.filter(
    (row) => !isFrozenDerivedRow(row, nowIso) && planCountKindSwitch(row, resolveCountKind(row), to) !== null,
  ).length;
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
