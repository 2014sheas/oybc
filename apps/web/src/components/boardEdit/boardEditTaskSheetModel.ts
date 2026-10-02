import { TaskType, generateCounterTaskTitle, type Task } from '@oybc/shared';
import type { BoardEditTaskOverride } from '../../hooks/squaresEditReducer';
import {
  childPatchFromTask,
  seedPatchForEditor,
  validatePatch,
  type TaskEditPatch,
} from '../../db/taskEditPatch';

/**
 * Pure model behind `BoardEditTaskSheet` (kept DOM-free so it is unit-testable
 * under node-only Vitest): which type control a task gets, how the compound
 * draft is seeded, whether the sheet is valid, and the staged override it
 * produces. Web twin of iOS `StagedTaskOverride` building.
 */

export type { BoardEditTaskOverride };

/** How the sheet presents the task's type. */
export type TypeControlMode = 'switch' | 'fixed' | 'none';

/**
 * Which type control the sheet shows: a Simple/Counting task gets the
 * three-way switch; a Compound shows its type fixed (switching OUT of a
 * compound is out of scope); Achievement shows none (title only).
 *
 * @param type - The task's current type.
 */
export function typeControlMode(type: TaskType): TypeControlMode {
  if (type === TaskType.NORMAL || type === TaskType.COUNTING) return 'switch';
  if (type === TaskType.COMPOUND) return 'fixed';
  return 'none';
}

/** Whether the compound editor is open for the chosen type. */
export function showsCompoundEditor(selected: TaskType): boolean {
  return selected === TaskType.COMPOUND;
}

/**
 * Seeds the compound draft exactly as Task Detail does. An existing compound
 * gets its live child tasks (in link order) as sub-tasks; a non-compound task
 * gets an empty-children draft with the default operator.
 *
 * @param task - The task being edited.
 * @param children - The compound's live child tasks, in `childIndex` order
 *   (ignored for a non-compound).
 */
export function seedCompoundDraft(task: Task, children: Task[]): TaskEditPatch {
  const seeded = seedPatchForEditor(task);
  if (task.type !== TaskType.COMPOUND) return { ...seeded, children: [] };
  return { ...seeded, children: children.filter((t) => !t.isDeleted).map(childPatchFromTask) };
}

/** The sheet's editable state. */
export interface SheetInput {
  /** The task as opened (overrides pre-merged by the caller). */
  original: Task;
  /** The type currently selected in the control. */
  selected: TaskType;
  title: string;
  action: string;
  goalStr: string;
  unit: string;
  /** `null` until the compound draft has loaded / been seeded. */
  compoundDraft: TaskEditPatch | null;
}

/** A positive-integer goal, or `null`. */
export function parseGoal(goalStr: string): number | null {
  const n = parseFloat(goalStr);
  return goalStr.trim() !== '' && Number.isInteger(n) && n > 0 ? n : null;
}

/**
 * The blocking message for the current sheet state, or `null` when Done may
 * proceed. Simple needs a title; Counting needs a positive goal + a unit
 * (title optional); Compound = `validatePatch` (title, ≥2 sub-tasks, counting
 * sub-task goal/unit, M_OF_N threshold). The DB-backed link guard runs at
 * Done (`compoundLinkProblemForPatch`) and again at Save.
 *
 * @param input - See {@link SheetInput}.
 */
export function sheetValidationProblem(input: SheetInput): string | null {
  const { selected, title } = input;
  switch (selected) {
    case TaskType.COUNTING:
      if (parseGoal(input.goalStr) === null) return 'Set a goal above zero.';
      if (input.unit.trim().length === 0) return 'Add a unit, like km or pages.';
      return null;
    case TaskType.COMPOUND:
      if (input.compoundDraft === null) return 'Loading sub-tasks…';
      return validatePatch({ ...input.compoundDraft, title }, TaskType.COMPOUND);
    default:
      return title.trim().length === 0 ? 'A title is required.' : null;
  }
}

/**
 * Builds the staged override for Done. Assumes {@link sheetValidationProblem}
 * returned `null`.
 *
 * - Simple → `{ title }` (+ `type`/cleared counting fields when switching
 *   from Counting: `action`/`unit`/`maxCount` are explicit `undefined`).
 * - Counting → title/action/goal/unit (+ `type` when switching from Simple;
 *   a blank title then auto-generates).
 * - Compound → `{ title, type?, compound }` — `compound` carries the whole
 *   structure (a later stage REPLACES it wholesale).
 *
 * `type` is only present when it differs from the task's current type.
 */
export function buildSheetOverride(input: SheetInput): BoardEditTaskOverride {
  const { original, selected } = input;
  const title = input.title.trim();
  const typeChanged = selected !== original.type;
  const patch: BoardEditTaskOverride = {};
  if (typeChanged) patch.type = selected;

  switch (selected) {
    case TaskType.COUNTING: {
      const goal = Math.max(1, parseGoal(input.goalStr) ?? 1);
      const action = input.action.trim();
      const unit = input.unit.trim();
      // Blank counting title = auto-generated. When merely editing an existing
      // Counting task keep its stored title (no flash while staged); on a
      // switch from Simple the old title is not a counting title.
      patch.title = title || (typeChanged ? generateCounterTaskTitle(action, goal, unit) : original.title);
      patch.action = action;
      patch.maxCount = goal;
      patch.unit = unit;
      break;
    }
    case TaskType.COMPOUND: {
      patch.title = title;
      if (input.compoundDraft) patch.compound = { ...input.compoundDraft, title };
      break;
    }
    default: {
      patch.title = title;
      if (original.type === TaskType.COUNTING) {
        patch.action = undefined;
        patch.unit = undefined;
        patch.maxCount = undefined;
      }
    }
  }
  return patch;
}
