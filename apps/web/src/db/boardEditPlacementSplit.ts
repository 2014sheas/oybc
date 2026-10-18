import {
  OperatorType,
  TaskType,
  convertGoalToKind,
  formatCountForInput,
  isAutoCounterTitle,
  generateCounterTaskTitle,
  parseCountInput,
  placementGoal,
  resolveCountKind,
  withPlacementParams,
  type CounterTitleSettings,
  type PlacementChildTarget,
  type PlacementParams,
  type Task,
} from '@oybc/shared';
import type { PlacementParamsPatch } from './operations/placementParams';
import type { UpdateTaskPatch } from './operations/tasks.crud';
import { applyStepToChildTask, type TaskEditPatch } from './taskEditPatch';

/**
 * boardEditPlacementSplit.ts — splits one Board Edit task override into the
 * part that lands on the PLACEMENT and the part that edits the task
 * (TASK_WINDOW_REWORK slice 3a, Gate 1 rulings b + c). Pure and DB-free.
 *
 * PARAMETER fields (placement): a counting task's goal (`maxCount` →
 * `targetOverride` + `targetKind`), any task's title (→ `titleOverride`), and
 * a compound's goal on an EXISTING counting child (→ `childTargets`).
 * EVERYTHING ELSE (action, unit, a kind switch, `type`, description, compound
 * structure: added / removed / reordered children, operator, threshold, a
 * child's title / action / unit) is a task edit and takes the board-scoped
 * fork path. A type change takes the whole override down that path untouched
 * (a conversion needs its own goal and title).
 */

/** A staged Board Edit override: task fields plus, for a compound, its structure. */
export type BoardEditOverride = UpdateTaskPatch & { compound?: TaskEditPatch };

/** Inputs of {@link splitBoardEditOverride}. */
export interface PlacementSplitInput {
  /** The STORED task (never the placement-adjusted or staged-merged one). */
  stored: Task;
  /** The task's placement on the edited board, when it has one. */
  placement?: PlacementParams | null;
  /** The staged override. */
  patch: BoardEditOverride;
  /** A compound's stored direct children, in link order (empty otherwise). */
  storedChildren?: Task[];
  /** The counter ROOT's name + templates for a linked row. */
  rootSettings?: CounterTitleSettings | null;
}

/** The two halves of a split. */
export interface PlacementSplit {
  /** Placement fields to set (value) or clear (`null`); empty = nothing to write. */
  params: PlacementParamsPatch;
  /** What remains for the task edit, or `null` when nothing does. */
  rest: BoardEditOverride | null;
}

const same = (a: unknown, b: unknown): boolean => (a ?? '') === (b ?? '');

/**
 * Whether the compound draft changes anything but existing children's goals.
 *
 * @param stored - The stored compound.
 * @param draft - The draft with existing children's goals already reset.
 * @param children - The stored children, in link order.
 * @returns `true` when the structure itself is edited.
 */
function structureEdited(stored: Task, draft: TaskEditPatch, children: Task[]): boolean {
  const byId = new Map(children.map((c) => [c.id, c]));
  const live = draft.children.filter((c) => !c.markedDeleted && c.title.trim().length > 0);
  if (live.length !== children.length) return true;
  if ((draft.operator ?? OperatorType.AND) !== (stored.operator ?? OperatorType.AND)) return true;
  if (draft.operator === OperatorType.M_OF_N && draft.threshold !== stored.threshold) return true;
  return live.some((step, i) => {
    const row = step.childTaskId ? byId.get(step.childTaskId) : undefined;
    if (!row || children[i]?.id !== row.id) return true;
    const next = applyStepToChildTask(row, step, step.title.trim());
    return next.title !== row.title || !same(next.action, row.action) || !same(next.unit, row.unit);
  });
}

/**
 * Splits a compound override: existing counting children's goals become
 * `childTargets` entries; any other structure change stays for the task edit.
 *
 * @param input - See {@link PlacementSplitInput}.
 * @param compound - The staged structure.
 * @returns The `childTargets` patch (if any) and the structure left for the task edit.
 */
function splitCompound(
  input: PlacementSplitInput,
  compound: TaskEditPatch,
): { childTargets?: PlacementChildTarget[] | null; compound?: TaskEditPatch } {
  const { stored, placement } = input;
  const children = input.storedChildren ?? [];
  const byId = new Map(children.map((c) => [c.id, c]));
  const entries = new Map((placement?.childTargets ?? []).map((e) => [e.childId, e.target]));
  let targetsChanged = false;
  const stripped = compound.children.map((step) => {
    const row = step.childTaskId ? byId.get(step.childTaskId) : undefined;
    if (!row || step.markedDeleted || step.title.trim().length === 0) return step;
    if (!step.isCounting || row.type !== TaskType.COUNTING) return step;
    const kind = resolveCountKind(row);
    const target = parseCountInput(step.goal, kind);
    if (target != null && target !== (entries.get(row.id) ?? row.maxCount)) {
      if (target === row.maxCount) entries.delete(row.id);
      else entries.set(row.id, target);
      targetsChanged = true;
    }
    return row.maxCount != null ? { ...step, goal: formatCountForInput(row.maxCount, kind) } : step;
  });
  const out: { childTargets?: PlacementChildTarget[] | null; compound?: TaskEditPatch } = {};
  if (targetsChanged) {
    out.childTargets = [...entries].map(([childId, target]) => ({ childId, target }));
    if (out.childTargets.length === 0) out.childTargets = null;
  }
  const draft: TaskEditPatch = { ...compound, children: stripped, title: stored.title };
  if (structureEdited(stored, draft, children)) out.compound = draft;
  return out;
}

/**
 * Split one staged override into placement parameters and a task edit.
 * "Changed" is judged against the effective value on this board (the stored
 * field with the placement's parameters applied), so saving the sheet without
 * edits writes nothing.
 *
 * @param input - See {@link PlacementSplitInput}.
 * @returns The {@link PlacementSplit}.
 */
export function splitBoardEditOverride(input: PlacementSplitInput): PlacementSplit {
  const { stored, placement, patch, rootSettings } = input;
  if ((patch.type ?? stored.type) !== stored.type) return { params: {}, rest: patch };

  const params: PlacementParamsPatch = {};
  const { compound, title, maxCount, countKind, type: _type, ...others } = patch;
  const rest: BoardEditOverride = {};
  for (const [k, v] of Object.entries(others)) {
    if (!same((stored as unknown as Record<string, unknown>)[k], v)) (rest as Record<string, unknown>)[k] = v;
  }

  const isCounting = stored.type === TaskType.COUNTING;
  const storedKind = resolveCountKind(stored);
  const kindSwitch = isCounting && countKind !== undefined && countKind !== storedKind;
  const newKind = kindSwitch ? countKind : storedKind;
  const settings = rootSettings ?? stored;
  if (kindSwitch) rest.countKind = countKind;

  // Goal → targetOverride (the task keeps its own).
  if (isCounting && maxCount != null) {
    const effective = placementGoal(stored, placement);
    const expected = effective == null ? undefined : convertGoalToKind(effective, storedKind, newKind);
    const own = stored.maxCount == null ? undefined : convertGoalToKind(stored.maxCount, storedKind, newKind);
    if (maxCount !== expected) {
      if (maxCount === own) params.targetOverride = null;
      else {
        params.targetOverride = maxCount;
        params.targetKind = newKind;
      }
    }
  }

  // Title → titleOverride (a title that is just the auto one carries no override).
  const patchTitle = title?.trim();
  if (patchTitle) {
    const effectiveTitle = withPlacementParams(stored, placement, rootSettings).title;
    if (patchTitle !== effectiveTitle) {
      const auto =
        isCounting &&
        isAutoCounterTitle(
          patchTitle,
          patch.action ?? stored.action ?? '',
          maxCount ?? stored.maxCount,
          patch.unit ?? stored.unit ?? '',
          newKind,
          settings,
        );
      if (patchTitle === stored.title || auto) {
        if (placement?.titleOverride) params.titleOverride = null;
      } else {
        params.titleOverride = patchTitle;
      }
    }
  }

  // An action / unit edit re-derives an auto title on the task itself, at the
  // task's OWN goal (the typed goal is a placement parameter).
  if (isCounting && ('action' in rest || 'unit' in rest)) {
    const storedAuto = isAutoCounterTitle(
      stored.title,
      stored.action ?? '',
      stored.maxCount,
      stored.unit ?? '',
      storedKind,
      settings,
    );
    if (storedAuto) {
      rest.title = generateCounterTaskTitle(
        patch.action ?? stored.action ?? '',
        stored.maxCount == null ? stored.maxCount : convertGoalToKind(stored.maxCount, storedKind, newKind),
        patch.unit ?? stored.unit ?? '',
        undefined,
        newKind,
        settings,
      );
    }
  }

  if (compound && stored.type === TaskType.COMPOUND) {
    const split = splitCompound(input, compound);
    if (split.childTargets !== undefined) params.childTargets = split.childTargets;
    if (split.compound) rest.compound = split.compound;
  }

  return { params, rest: Object.keys(rest).length > 0 ? rest : null };
}
