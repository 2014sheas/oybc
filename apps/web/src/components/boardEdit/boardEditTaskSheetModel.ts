import {
  OperatorType,
  TaskType,
  countKindNeedsUnit,
  countTargetStep,
  generateCounterTaskTitle,
  isAutoCounterTitle,
  parseCountInput,
  resolveCountKind,
  type CountKind,
  type Task,
} from '@oybc/shared';
import type { BoardEditTaskOverride } from '../../hooks/squaresEditReducer';
import { compoundStructureChanged } from '../../pages/tasks/compoundEditGate';
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

/** Whether the compound editor is open for the chosen type. */
export function showsCompoundEditor(selected: TaskType): boolean {
  return selected === TaskType.COMPOUND;
}

/**
 * What the sheet's Title field opens with. A Counting task whose stored title
 * is still its AUTO one (`isAutoCounterTitle`) seeds BLANK so the title keeps
 * re-deriving as Action/Goal/Unit change — seeded as text it would read as a
 * chosen name and `buildSheetOverride` would carry the stale "Run 10 miles"
 * onto a goal of 5. A custom title (and any other type) seeds verbatim.
 * Mirrors `seedPatchForEditor` (`db/taskEditPatch.ts`) and iOS
 * `SquareEditTaskSheet.seededTitle(for:)`.
 *
 * @param task - The task being edited (any staged override already merged).
 */
export function seedSheetTitle(task: Task): string {
  const title = task.title ?? '';
  if (
    task.type === TaskType.COUNTING &&
    isAutoCounterTitle(title, task.action ?? '', task.maxCount, task.unit ?? '', resolveCountKind(task))
  ) {
    return '';
  }
  return title;
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
  // A converted compound must never be written without an operator (iOS `.and`).
  if (task.type !== TaskType.COMPOUND) {
    return { ...seeded, operator: seeded.operator ?? OperatorType.AND, children: [] };
  }
  return { ...seeded, children: children.filter((t) => !t.isDeleted).map(childPatchFromTask) };
}

/** The sheet's editable state. */
export interface SheetInput {
  /**
   * The task as it was BEFORE any staged override (stored or pending). Its
   * type is what `buildSheetOverride` diffs against, so selecting it again
   * stages no type change.
   */
  original: Task;
  /** The type currently selected in the control. */
  selected: TaskType;
  title: string;
  action: string;
  goalStr: string;
  unit: string;
  /** The kind the picker shows — the Goal parses at it; Duration needs no unit. */
  countKind: CountKind;
  /** `null` until the compound draft has loaded / been seeded. */
  compoundDraft: TaskEditPatch | null;
  /**
   * The structure seeded from the STORED compound (`null` when unknown — a
   * staged structure was re-opened, or the original is not a compound). Lets
   * an unedited compound skip structure validation / submission.
   */
  compoundBaseline?: TaskEditPatch | null;
}

/**
 * Whether the compound structure must be validated / submitted: always for a
 * non-compound original (a conversion), and for an existing compound only when
 * its rule / sub-tasks differ from the stored baseline (so a stored-invalid
 * compound can still be renamed — iOS parity).
 */
export function compoundStructureEdited(input: SheetInput): boolean {
  if (input.original.type !== TaskType.COMPOUND) return true;
  if (input.compoundBaseline == null) return true;
  return compoundStructureChanged(input.compoundBaseline, input.compoundDraft);
}

/**
 * The goal the Goal field holds at `kind` (a positive whole number for
 * Discrete, up to 2 dp for Continuous, minutes for Duration), or `null`.
 *
 * @param goalStr - The Goal field's text.
 * @param kind - The sheet's kind. Defaults to Discrete.
 */
export function parseGoal(goalStr: string, kind: CountKind = 'discrete'): number | null {
  return parseCountInput(goalStr, kind);
}

/**
 * The blocking message for the current sheet state, or `null` when Done may
 * proceed. Simple needs a title; Counting needs a positive goal at the
 * sheet's kind + a unit unless it is Duration (title optional); Compound = `validatePatch` (title, ≥1 sub-task, counting
 * sub-task goal/unit, M_OF_N threshold). The DB-backed link guard runs at
 * Done (`compoundLinkProblemForPatch`) and again at Save.
 *
 * @param input - See {@link SheetInput}.
 */
export function sheetValidationProblem(input: SheetInput): string | null {
  const { selected, title } = input;
  switch (selected) {
    case TaskType.COUNTING:
      if (parseGoal(input.goalStr, input.countKind) === null) return 'Set a goal above zero.';
      if (countKindNeedsUnit(input.countKind) && input.unit.trim().length === 0) return 'Add a unit, like km or pages.';
      return null;
    case TaskType.COMPOUND:
      if (input.compoundDraft === null) return 'Loading sub-tasks…';
      if (!compoundStructureEdited(input)) {
        return title.trim().length === 0 ? 'A title is required.' : null;
      }
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
 * - Counting → title/action/goal/unit/countKind (+ `type` when switching
 *   from Simple); a blank title auto-generates from the sheet's
 *   action/goal/unit at its kind. `countKind` is applied at Save through the
 *   kind switch (`applyBoardEditTaskOverrideInTransaction`).
 * - Compound → `{ title, type?, compound }` — `compound` carries the whole
 *   structure (a later stage REPLACES it wholesale).
 *
 * `type` is only present when it differs from the task's current type.
 */
export function buildSheetOverride(input: SheetInput): BoardEditTaskOverride {
  const { original, selected } = input;
  const title = input.title.trim();
  // `compound: undefined` on EVERY non-compound branch: the reducer spreads,
  // so a stale staged structure would otherwise survive a switch back.
  const patch: BoardEditTaskOverride = { compound: undefined };
  // Explicit `type` always (even back to the original) so a stale staged type
  // is overwritten; the commit op treats type === stored as unchanged.
  patch.type = selected;

  switch (selected) {
    case TaskType.COUNTING: {
      const goal = parseGoal(input.goalStr, input.countKind) ?? countTargetStep(input.countKind);
      const action = input.action.trim();
      // Duration hides Unit but keeps the row's own (a hub counter's noun names it).
      const unit = input.unit.trim();
      // Blank counting title = auto-generated from the sheet's CURRENT
      // action / goal / unit — exactly what the "Reads as" preview shows. The
      // field opens blank for an auto-titled task (`seedSheetTitle`), so a
      // goal-only edit regenerates the title instead of keeping the stored
      // one at the old goal.
      patch.title = title || generateCounterTaskTitle(action, goal, unit, undefined, input.countKind);
      patch.action = action;
      patch.maxCount = goal;
      patch.unit = unit;
      patch.countKind = input.countKind;
      break;
    }
    case TaskType.COMPOUND: {
      patch.title = title;
      if (input.compoundDraft && compoundStructureEdited(input)) patch.compound = { ...input.compoundDraft, title };
      break;
    }
    default: {
      patch.title = title;
      if (original.type === TaskType.COUNTING) {
        patch.action = undefined;
        patch.unit = undefined;
        patch.maxCount = undefined;
        // `countKind` is never cleared (sync merge-writes; a clear would not
        // reach other devices) — a non-counting type ignores it.
      }
    }
  }
  return patch;
}
