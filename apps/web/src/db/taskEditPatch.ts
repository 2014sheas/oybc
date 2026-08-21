import { OperatorType, TaskType, generateCounterTaskTitle, clampCompoundThreshold, type CompoundChild, type Task } from '@oybc/shared';
import { generateUUID, currentTimestamp } from './utils';

/**
 * Web port of iOS `TaskEditPatch.swift` (Inline Task Editing, web PR-2).
 *
 * A staged, not-yet-persisted edit to a pooled task — created/edited by
 * `PoolRowEditor`, staged on `useBoardWizard`'s `stagedEdits` map, and
 * applied ONLY inside the board-create transaction (`persistWizardBoardRows`
 * / `persistWizardPendingTasks`, `db/operations/wizardBoard.ts`) — never
 * while the board is a draft. Pure, DB-free logic lives here so it can be
 * unit-tested without touching Dexie; see `db/operations/wizardBoard.ts`
 * for the write-time application.
 *
 * `goal` is a string (not a number) so an in-progress empty field is
 * representable while the user types — mirrors the Swift struct's
 * rationale verbatim.
 */

/** Lives at `apps/web/src/db/` (a sibling of `db/utils.ts`), not under
 *  `components/wizard/`, so both `db/operations/wizardBoard.ts` (the
 *  write-time applier) and `components/wizard/PoolRowEditor.tsx` (the UI)
 *  can import it without an operations→components dependency inversion. */

/**
 * Shared "Reads as: Action — Goal — Unit" live preview for counting-task
 * and compound counting sub-task editors. Returns `undefined` when all
 * three fields are blank; blanks render as an em dash. Mirrors iOS
 * `risoReadsAsPreview`.
 */
export function readsAsPreview(action: string, goal: string, unit: string): string | undefined {
  const a = action.trim();
  const g = goal.trim();
  const u = unit.trim();
  if (!a && !g && !u) return undefined;
  return `Reads as: ${a || '—'} — ${g || '—'} — ${u || '—'}`;
}

/** A single compound sub-task edit. Mirrors iOS `ChildPatch`. */
export interface ChildPatch {
  /** Stable identity for React keys: the child task id for existing
   *  links, or a fresh UUID for a not-yet-created sub-task. */
  id: string;
  /** `null` ⇒ a new sub-task created in the editor (see `isNewChild`). */
  childTaskId: string | null;
  title: string;
  /** A counting sub-task is a Counting child (Action/Goal/Unit);
   *  otherwise a Normal sub-task. A sub-task's type is fixed once added. */
  isCounting: boolean;
  action: string;
  goal: string;
  unit: string;
  markedDeleted: boolean;
}

/** `true` when the child was created in this editor session (no real Task
 *  row yet). Mirrors iOS `ChildPatch.isNew`. */
export function isNewChild(child: ChildPatch): boolean {
  return child.childTaskId === null;
}

/** Builds a fresh sub-task row for the "+ Normal/Counting sub-task"
 *  buttons. Mirrors iOS `addSubtaskButton`'s construction. */
export function newChildPatch(isCounting: boolean): ChildPatch {
  return {
    id: generateUUID(),
    childTaskId: null,
    title: '',
    isCounting,
    action: '',
    goal: '',
    unit: '',
    markedDeleted: false,
  };
}

/** Clone a sub-task from an existing child Task. A Counting child is a
 *  "counting" sub-task (Action/Goal/Unit); anything else is a Normal
 *  sub-task. Mirrors iOS `ChildPatch.init(from:)`. */
export function childPatchFromTask(child: Task): ChildPatch {
  return {
    id: child.id,
    childTaskId: child.id,
    title: child.title,
    isCounting: child.type === TaskType.COUNTING,
    action: child.action ?? '',
    goal: child.maxCount !== undefined ? String(child.maxCount) : '',
    unit: child.unit ?? '',
    markedDeleted: false,
  };
}

/** A staged, not-yet-persisted edit to a pooled task. See module doc. */
export interface TaskEditPatch {
  title: string;
  action: string;
  goal: string;
  unit: string;
  children: ChildPatch[];
  /** Compound completion operator. Seeded from `Task.operator` on open;
   *  written back onto the Task row in `applyPatchToTask`. `undefined` for
   *  non-compound patches (never read). */
  operator?: OperatorType;
  /** Compound "at least N" threshold. Only meaningful when
   *  `operator === OperatorType.M_OF_N`; `applyPatchToTask` clamps it into
   *  `[1, max(1, liveChildren.length)]` and clears it for AND/OR. */
  threshold?: number;
}

/** A fresh patch with just a title — used by callers that build up the
 *  rest of the shape incrementally (mirrors iOS `TaskEditPatch(title:)`). */
export function emptyPatch(title = ''): TaskEditPatch {
  return { title, action: '', goal: '', unit: '', children: [] };
}

/** Clone the editable fields from a task on open. Compound children are
 *  populated by the caller from the compound's resolved child tasks (in
 *  `childIndex` order). Mirrors iOS `TaskEditPatch.init(from:)`. */
export function patchFromTask(task: Task): TaskEditPatch {
  return {
    title: task.title,
    action: task.action ?? '',
    goal: task.maxCount !== undefined ? String(task.maxCount) : '',
    unit: task.unit ?? '',
    children: [],
    operator: task.operator,
    threshold: task.threshold,
  };
}

/**
 * Editor-seeding variant of `patchFromTask` — used only when the inline
 * pool-row editor opens a row for the FIRST time (reopens reuse the staged
 * patch verbatim). For a Counting task whose stored title still matches its
 * auto-generated form, seeds the Title field BLANK so it keeps
 * auto-deriving as Action/Goal/Unit change in the editor — a non-blank
 * seeded title reads as "custom" in `applyPatchToTask` and would otherwise
 * never re-derive. A genuinely custom title is preserved verbatim. Mirrors
 * iOS `TaskEditPatch.seededForEditor(from:)`.
 */
export function seedPatchForEditor(task: Task): TaskEditPatch {
  const patch = patchFromTask(task);
  if (task.type === TaskType.COUNTING) {
    const autoTitle = generateCounterTaskTitle(task.action ?? '', task.maxCount, task.unit ?? '');
    if (task.title === autoTitle) {
      return { ...patch, title: '' };
    }
  }
  return patch;
}

/** Kept sub-tasks — excludes deleted and blank-titled entries (dropped on
 *  save). Shared by validation, apply-at-create clamping, the inline rule
 *  picker's max clamp, and the pool's staged-overlay subtitle/preview.
 *  Mirrors iOS `TaskEditPatch.liveChildren`. */
export function liveChildren(patch: TaskEditPatch): ChildPatch[] {
  return patch.children.filter((c) => !c.markedDeleted && c.title.trim().length > 0);
}

/** Live "Reads as: Action — Goal — Unit" preview for counting editors.
 *  `undefined` when all three fields are blank. Mirrors iOS
 *  `TaskEditPatch.countingPreview`. */
export function countingPreview(patch: TaskEditPatch): string | undefined {
  return readsAsPreview(patch.action, patch.goal, patch.unit);
}

/** Clamp an "at least N" threshold into `[1, max(1, count)]` — shared by
 *  the rule-picker's live clamp and a sub-task delete's clamp. Thin web
 *  alias over the cross-platform `clampCompoundThreshold` (`@oybc/shared`)
 *  so web and iOS can't drift on the clamp bounds. */
export function clampThreshold(threshold: number, subtaskCount: number): number {
  return clampCompoundThreshold(threshold, subtaskCount);
}

/**
 * The blocking validation message, or `null` when the patch is valid for
 * the given task type. Handles NORMAL, COUNTING, and COMPOUND; ACHIEVEMENT
 * isn't editable in the pool (returns `null`). Mirrors iOS
 * `TaskEditPatch.validate(type:)`.
 */
export function validatePatch(patch: TaskEditPatch, type: TaskType): string | null {
  const trimmedTitle = patch.title.trim();
  switch (type) {
    case TaskType.COUNTING: {
      // Counting titles are optional (auto-generated), so no title check.
      const g = parseInt(patch.goal.trim(), 10);
      if (!Number.isFinite(g) || g <= 0) return 'Set a goal above zero.';
      if (patch.unit.trim().length === 0) return 'Add a unit, like km or pages.';
      return null;
    }
    case TaskType.NORMAL:
      return trimmedTitle.length === 0 ? 'A title is required.' : null;
    case TaskType.COMPOUND: {
      if (trimmedTitle.length === 0) return 'A title is required.';
      const kept = liveChildren(patch);
      if (kept.length < 2) return 'A compound task needs at least two sub-tasks.';
      for (const child of kept) {
        if (!child.isCounting) continue;
        const g = parseInt(child.goal.trim(), 10);
        const u = child.unit.trim();
        if (!Number.isFinite(g) || g <= 0 || u.length === 0) {
          const name = child.title.trim();
          return `Counting sub-task "${name}" needs a goal and a unit.`;
        }
      }
      if (patch.operator === OperatorType.M_OF_N) {
        const t = patch.threshold;
        if (t === undefined || t < 1 || t > kept.length) {
          return 'Choose how many sub-tasks must complete.';
        }
      }
      return null;
    }
    default:
      return null;
  }
}

/**
 * Applies the patch's title/counting/compound-rule fields to a base task.
 * Assumes `validatePatch` already passed. Does NOT bump `version`/
 * `updatedAt` — the persist caller owns that. Compound child Task/link CRUD
 * is applied by the persist layer (`applyStagedCompoundChildEdits` in
 * `db/operations/wizardBoard.ts`), not here. Mirrors iOS
 * `TaskEditPatch.applied(to:)`.
 */
export function applyPatchToTask(patch: TaskEditPatch, base: Task): Task {
  const trimmedTitle = patch.title.trim();
  switch (base.type) {
    case TaskType.COUNTING: {
      const a = patch.action.trim();
      const u = patch.unit.trim();
      const parsedGoal = parseInt(patch.goal.trim(), 10);
      const g = Number.isFinite(parsedGoal) ? parsedGoal : (base.maxCount ?? 0);
      const title = trimmedTitle.length === 0 ? generateCounterTaskTitle(a, g, u) : trimmedTitle;
      return { ...base, action: a, unit: u, maxCount: g, title };
    }
    case TaskType.COMPOUND: {
      // Parent-level fields only; child Task/link CRUD is applied by the
      // persist layer, not here.
      let operator = patch.operator;
      let threshold: number | undefined;
      if (operator === OperatorType.M_OF_N) {
        threshold = clampCompoundThreshold(patch.threshold ?? 1, liveChildren(patch).length);
      } else {
        threshold = undefined;
      }
      return { ...base, title: trimmedTitle, operator, threshold };
    }
    default:
      return { ...base, title: trimmedTitle };
  }
}

/**
 * Builds a fresh child Task row for a newly-added compound sub-task
 * (`isNewChild(step)`). Pure — the caller (`db/operations/wizardBoard.ts`)
 * owns the actual `db.tasks.add` + sync-enqueue. Mirrors iOS
 * `AppDatabase.makeStagedChildTask`.
 */
export function buildNewChildTask(
  id: string,
  step: ChildPatch,
  title: string,
  userId: string,
  now: string,
): Task {
  if (step.isCounting) {
    const action = step.action.trim();
    const unit = step.unit.trim();
    const parsedGoal = parseInt(step.goal.trim(), 10);
    const goal = Number.isFinite(parsedGoal) ? parsedGoal : 0;
    return {
      id,
      userId,
      title: generateCounterTaskTitle(action, goal, unit, title),
      type: TaskType.COUNTING,
      action,
      unit,
      maxCount: goal,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    };
  }
  return {
    id,
    userId,
    title,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };
}

/**
 * Applies a sub-task's edited fields onto its existing child Task (title,
 * and for a counting sub-task the action/goal/unit + regenerated counting
 * title). Returns the (possibly unchanged) task; the caller bumps version
 * if different. Mirrors iOS `AppDatabase.applyStagedStepToChild`.
 */
export function applyStepToChildTask(base: Task, step: ChildPatch, title: string): Task {
  if (step.isCounting && base.type === TaskType.COUNTING) {
    const action = step.action.trim();
    const unit = step.unit.trim();
    const parsedGoal = parseInt(step.goal.trim(), 10);
    const goal = Number.isFinite(parsedGoal) ? parsedGoal : (base.maxCount ?? 0);
    return { ...base, action, unit, maxCount: goal, title: generateCounterTaskTitle(action, goal, unit, title) };
  }
  return { ...base, title };
}

/** Deep-equality check for two patches — used by the editor's Discard
 *  handler to tell whether the draft actually changed from its opened
 *  baseline (a plain `patchFromTask` snapshot never carries compound
 *  children, so comparing against it would falsely report "changed" for
 *  every compound — callers must compare against the baseline the editor
 *  actually opened with, exactly like iOS's `editBaseline`). */
export function patchesEqual(a: TaskEditPatch, b: TaskEditPatch): boolean {
  if (
    a.title !== b.title ||
    a.action !== b.action ||
    a.goal !== b.goal ||
    a.unit !== b.unit ||
    a.operator !== b.operator ||
    a.threshold !== b.threshold ||
    a.children.length !== b.children.length
  ) {
    return false;
  }
  for (let i = 0; i < a.children.length; i++) {
    const x = a.children[i];
    const y = b.children[i];
    if (
      x.id !== y.id ||
      x.childTaskId !== y.childTaskId ||
      x.title !== y.title ||
      x.isCounting !== y.isCounting ||
      x.action !== y.action ||
      x.goal !== y.goal ||
      x.unit !== y.unit ||
      x.markedDeleted !== y.markedDeleted
    ) {
      return false;
    }
  }
  return true;
}

// ─── UI-side overlay helpers (Tasks-step pool subtitle + preview) ──────────
//
// These merge staged edits INTO read-only display maps so the pool-row
// subtitle, the compound-children preview, and the Step-3 preview grid all
// reflect an unsaved edit immediately — the DB stays untouched until board
// create. Mirrors iOS `effectiveCompoundChildrenByCompound` /
// `stagedNewChildPlaceholders` / `BoardWizardTasksStepView.effectiveTaskById`
// (`BoardWizardPersist.swift`).

/**
 * Overlays `stagedEdits` onto a task map (id → Task) so a row/preview shows
 * an unsaved rename/goal/compound-rule change immediately. Ids with no
 * staged edit (or whose base task can't be found) pass through untouched.
 */
export function overlayTaskMapWithStagedEdits(
  base: Record<string, Task>,
  stagedEdits: Map<string, TaskEditPatch>,
): Record<string, Task> {
  if (stagedEdits.size === 0) return base;
  const merged = { ...base };
  for (const [id, patch] of stagedEdits) {
    const b = merged[id];
    if (b) merged[id] = applyPatchToTask(patch, b);
  }
  return merged;
}

/**
 * Merges a staged compound edit's KEPT sub-tasks into a
 * `compoundTaskId → CompoundChild[]` map, replacing the base entry with
 * synthesized links in draft order — the single source of truth for "how
 * many sub-tasks does this compound have right now" while its editor is
 * open (or was staged and closed). A brand-new sub-task (no real
 * `childTaskId` yet) gets the synthetic id `staged-child-<patchChildId>` —
 * pair with `stagedNewChildPlaceholders` so a type-dependent read (e.g. the
 * "N with a goal" subcount) can resolve it. Mirrors iOS
 * `effectiveCompoundChildrenByCompound`.
 */
export function overlayCompoundChildrenWithStagedEdits(
  base: Record<string, CompoundChild[]>,
  stagedEdits: Map<string, TaskEditPatch>,
): Record<string, CompoundChild[]> {
  if (stagedEdits.size === 0) return base;
  const merged = { ...base };
  const now = currentTimestamp();
  for (const [taskId, patch] of stagedEdits) {
    const kept = liveChildren(patch);
    if (kept.length === 0) continue;
    merged[taskId] = kept.map((child, index) => ({
      id: `staged-${taskId}-${child.id}`,
      compoundTaskId: taskId,
      childTaskId: child.childTaskId ?? `staged-child-${child.id}`,
      childIndex: index,
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    }));
  }
  return merged;
}

/**
 * Synthesizes placeholder `Task` entries for brand-new staged compound
 * sub-tasks (no real Task row yet), keyed by the same synthetic id
 * `overlayCompoundChildrenWithStagedEdits` uses for their `childTaskId`
 * (`staged-child-<patchChildId>`), so a type-dependent lookup resolves
 * correctly for a sub-task that only exists in the draft so far. Mirrors
 * iOS `stagedNewChildPlaceholders`.
 */
export function stagedNewChildPlaceholders(
  userId: string,
  stagedEdits: Map<string, TaskEditPatch>,
): Record<string, Task> {
  if (stagedEdits.size === 0) return {};
  const now = currentTimestamp();
  const placeholders: Record<string, Task> = {};
  for (const patch of stagedEdits.values()) {
    for (const child of liveChildren(patch)) {
      if (!isNewChild(child)) continue;
      const id = `staged-child-${child.id}`;
      placeholders[id] = {
        id,
        userId,
        title: child.title,
        type: child.isCounting ? TaskType.COUNTING : TaskType.NORMAL,
        isCompleted: false,
        totalCompletions: 0,
        totalInstances: 0,
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
      };
    }
  }
  return placeholders;
}
