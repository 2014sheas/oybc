import { TaskType } from '@oybc/shared';

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
 * @param locked - True for a linked counter (`sharedCounterId != null`): its
 *   type is fixed. (A counter ROOT with live copies is refused at Done / Save
 *   with `SHARED_COUNTER_TYPE_MESSAGE` — a DB fact, not shown by the control.)
 */
export function typeControlMode(type: TaskType, locked = false): TypeControlMode {
  if (type === TaskType.ACHIEVEMENT) return 'none';
  if (locked) return 'fixed';
  if (type === TaskType.NORMAL || type === TaskType.COUNTING) return 'switch';
  if (type === TaskType.COMPOUND) return 'fixed';
  return 'none';
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
