import {
  SyncOperationType,
  TaskType,
  isFrozenDerivedRow,
  planCountKindSwitch,
  propagateIncrement,
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
  const nowIso = now.toISOString();
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
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
    },
  );
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
