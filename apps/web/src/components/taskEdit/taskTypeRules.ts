import { TaskType, type Task } from '@oybc/shared';

/**
 * The one type-control rule shared by every editor that edits a task row —
 * the Board Edit square sheet (`BoardEditTaskSheet`) and the global editor
 * (`TaskEditSheet`, Task Detail + Tasks tab). Pure, so it is unit-testable
 * under node-only Vitest. The write side is
 * `applyTaskTypeSwitchInTransaction` (`db/operations/compoundStructureEdit.ts`).
 * iOS twin: `TaskTypeSwitch` (`Helpers/TaskTypeSwitch.swift`).
 */

/** How an editor presents the task's type. */
export type TypeControlMode = 'switch' | 'fixed' | 'none';

/**
 * Which type control an editor shows: a Simple/Counting task gets the
 * three-way switch; a Compound shows its type fixed (switching OUT of a
 * compound is not offered); Achievement shows none.
 *
 * @param type - The task's ORIGINAL (stored / pending) type, not an override-merged one.
 * @param locked - {@link typeLockedForEdit}: true for any shared counter — its type is fixed.
 */
export function typeControlMode(type: TaskType, locked = false): TypeControlMode {
  if (type === TaskType.ACHIEVEMENT) return 'none';
  if (locked) return 'fixed';
  if (type === TaskType.NORMAL || type === TaskType.COUNTING) return 'switch';
  if (type === TaskType.COMPOUND) return 'fixed';
  return 'none';
}

/**
 * Whether a task's type is fixed because it is a SHARED COUNTER (owner rule
 * 2026-10-09: a shared counter's type is never changeable): a linked copy
 * (`sharedCounterId` set), a hub counter (`isCounter`), or a counting task
 * that other rows link to (a board-born root — `hasLinkedCopies`, resolved by
 * `useHasLiveLinkedCopies`). The save refuses it too
 * (`SHARED_COUNTER_TYPE_MESSAGE`) — that stays as the backstop.
 * iOS twin: `TaskTypeSwitch.showsPicker(task:original:hasLinkedCopies:)`.
 *
 * @param task - The task's stored (original) row.
 * @param hasLinkedCopies - Whether any live row links to it as its root.
 * @returns True when the editor shows the type fixed.
 */
export function typeLockedForEdit(
  task: Pick<Task, 'type' | 'sharedCounterId' | 'isCounter'>,
  hasLinkedCopies: boolean,
): boolean {
  return (
    task.sharedCounterId != null ||
    task.isCounter === true ||
    (task.type === TaskType.COUNTING && hasLinkedCopies)
  );
}

/** The switch's segments (labels shared with iOS). */
export const TYPE_OPTIONS = [
  { value: TaskType.NORMAL, label: 'Simple' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: TaskType.COMPOUND, label: 'Compound' },
];

/**
 * Human-readable type label for the fixed type indicator.
 *
 * @param type - The task type.
 */
export function typeLabel(type: TaskType | string): string {
  switch (type) {
    case TaskType.NORMAL:      return 'Simple';
    case TaskType.COUNTING:    return 'Counting';
    case TaskType.COMPOUND:    return 'Compound';
    case TaskType.ACHIEVEMENT: return 'Achievement';
    default:                   return String(type);
  }
}
