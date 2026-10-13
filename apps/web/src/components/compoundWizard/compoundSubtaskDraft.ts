import {
  TaskType,
  counterDisplayName,
  countKindNeedsUnit,
  counterPickGoal,
  formatCountForInput,
  findLinkableCounter,
  generateCounterTaskTitle,
  parseCountInput,
  renderCounterTitle,
  resolveCountKind,
  type CountKind,
  type CreateCompoundChildEntry,
  type PlacementBoard,
  type LinkableCounter,
  type Task,
} from '@oybc/shared';
import type { SubtaskFormState } from '../subtaskDraftUtils';

/** The inline task types a SubtaskCard can create. Nested compound-of-
 *  compound subtasks can't be built inline — they must already exist in
 *  the library. Ordered compounds (formerly "progress") are created
 *  through the Compound wizard, not as inline subtasks. */
export type InlineSubtaskType = 'normal' | 'counting';

/** Existing-mode draft: points at a Task or compound Task already in the
 *  library. `selectionType` is derived from which list the id came from
 *  and used purely for the chip badge in Review. */
export interface ExistingSubtaskDraft {
  id: string;
  mode: 'existing';
  selectionType: 'task' | 'compound';
  selectedId: string;
}

/** Inline-mode draft: the user is creating a brand-new Task inside the
 *  compound. On save, the Task row lands in the library AND becomes a
 *  child of the compound. */
export interface InlineSubtaskDraft {
  id: string;
  mode: 'inline';
  inlineType: InlineSubtaskType;
  title: string;
  action: string;
  unit: string;
  maxCountStr: string;
  steps: SubtaskFormState[];
  /** When a user clicks a different type button while the current type
   *  has dirty fields, the click is pending until they confirm switching
   *  (and losing the current fields). Null/undefined = no pending switch. */
  pendingTypeSwitch?: InlineSubtaskType;
  /**
   * R1 counters refresh — auto-link opt-out. When the typed (action, unit)
   * pair exactly matches an existing counter, linking is ON by default
   * (see `CounterLinkHint`); setting this `true` is the "Don't link" opt-out
   * for this create. Reset to `false` whenever `action`/`unit` change so a
   * fresh pair always starts linked. Only meaningful when
   * `inlineType === 'counting'`.
   */
  linkDisabled?: boolean;
  /** Counter kind of a NEW counting sub-task (absent = discrete). Only a
   *  sub-task that does not auto-link shows the picker; a linked one follows
   *  its root's kind (see {@link effectiveInlineKind}). */
  countKind?: CountKind;
  /** A hub counter picked from the library list: the link target while the
   *  draft's verb / noun / kind still match it (see {@link inlineLinkMatch}) —
   *  so a Duration counter links too. */
  pinnedCounterId?: string;
}

/**
 * The inline Counting draft a picked counter becomes: its verb, noun and kind,
 * pinned to it, the goal pre-filled with the counter's default for `window`
 * (`counterPickGoal`; editable). iOS twin: `RisoCompoundFieldsView.prefillCounterSub`.
 *
 * @param root - The picked counter.
 * @param id - The draft id.
 * @param window - The host's window, if any (none reads as Indefinite → yearly).
 * @returns The draft.
 */
export function inlineSubtaskFromCounter(root: Task, id: string, window?: PlacementBoard | null): InlineSubtaskDraft {
  const kind = resolveCountKind(root);
  const goal = counterPickGoal(root, window);
  return {
    id,
    mode: 'inline',
    inlineType: 'counting',
    title: '',
    action: root.action ?? '',
    unit: countKindNeedsUnit(kind) ? (root.unit ?? '') : '',
    maxCountStr: goal !== null ? formatCountForInput(goal, kind) : '',
    steps: [],
    ...(kind !== 'discrete' ? { countKind: kind } : {}),
    pinnedCounterId: root.id,
  };
}

/**
 * The pinned counter, while the draft still names it (verb, noun when the
 * kind has one, kind).
 *
 * @param draft - The inline draft.
 * @param allTasks - The library pool.
 * @returns The pinned root, or undefined.
 */
function pinnedRoot(draft: InlineSubtaskDraft, allTasks: readonly Task[]): Task | undefined {
  if (!draft.pinnedCounterId || draft.inlineType !== 'counting') return undefined;
  const root = allTasks.find((t) => t.id === draft.pinnedCounterId && !t.isDeleted);
  if (!root) return undefined;
  const kind = draft.countKind ?? 'discrete';
  if (kind !== resolveCountKind(root)) return undefined;
  if (draft.action.trim() !== (root.action ?? '').trim()) return undefined;
  if (countKindNeedsUnit(kind) && draft.unit.trim() !== (root.unit ?? '').trim()) return undefined;
  return root;
}

export type SubtaskDraft = ExistingSubtaskDraft | InlineSubtaskDraft;

/** Result of checking whether a subtask draft is ready to ship as part of
 *  the compound. `message` is a plain-English hint suitable for inline
 *  rendering under the card. */
export interface SubtaskReadiness {
  ready: boolean;
  message: string | null;
}

/**
 * Live validator — pure, no side-effects. Used for the green/red card
 * border and the per-card readiness message so users don't have to
 * click "Done" or "Submit" to discover what's missing.
 */
export function evaluateSubtaskReadiness(
  draft: SubtaskDraft,
  excludedIds: Set<string>,
  allTasks: readonly Task[] = [],
): SubtaskReadiness {
  if (draft.mode === 'existing') {
    if (!draft.selectedId) {
      return { ready: false, message: 'Pick a task or compound from your library.' };
    }
    if (excludedIds.has(draft.selectedId)) {
      return { ready: false, message: 'Already selected in another card.' };
    }
    return { ready: true, message: null };
  }

  switch (draft.inlineType) {
    case 'normal':
      if (!draft.title.trim()) return { ready: false, message: 'Add a title for this task.' };
      return { ready: true, message: null };

    case 'counting': {
      if (!draft.action.trim()) return { ready: false, message: 'Add an action (e.g. "Run").' };
      const kind = effectiveInlineKind(draft, allTasks);
      if (countKindNeedsUnit(kind) && !draft.unit.trim()) {
        return { ready: false, message: 'Add a unit (e.g. "miles").' };
      }
      if (parseCountInput(draft.maxCountStr, kind) === null) {
        return { ready: false, message: 'Add a goal above zero.' };
      }
      return { ready: true, message: null };
    }

  }
}

/**
 * Returns true if the inline draft has any user-entered content for its
 * current type. Used to decide whether to prompt before switching types
 * (so we don't silently wipe a partly-filled counting form).
 */
export function hasInlineDirtyFields(draft: InlineSubtaskDraft): boolean {
  const titleDirty = draft.title.trim().length > 0;
  switch (draft.inlineType) {
    case 'normal':
      return titleDirty;
    case 'counting':
      return (
        titleDirty ||
        draft.action.trim().length > 0 ||
        draft.unit.trim().length > 0 ||
        draft.maxCountStr.trim().length > 0
      );
  }
}

/**
 * Returns a draft with all fields for the current inline type cleared,
 * the `inlineType` replaced with `nextType`, and `pendingTypeSwitch`
 * cleared. The subtask id is preserved.
 */
export function switchInlineType(
  draft: InlineSubtaskDraft,
  nextType: InlineSubtaskType,
): InlineSubtaskDraft {
  return {
    id: draft.id,
    mode: 'inline',
    inlineType: nextType,
    title: '',
    action: '',
    unit: '',
    maxCountStr: '',
    steps: [],
    pendingTypeSwitch: undefined,
  };
}

/**
 * The counter a NEW inline counting sub-task would auto-link to, ignoring the
 * "Don't link" opt-out (the hint still shows so the user can re-link). Duration
 * has no counted noun, so it never matches.
 *
 * @param draft - The inline sub-task draft.
 * @param allTasks - The library pool.
 * @returns The matched root counter, or null.
 */
export function inlineLinkMatch(
  draft: InlineSubtaskDraft,
  allTasks: readonly Task[],
): LinkableCounter | null {
  const pinned = pinnedRoot(draft, allTasks);
  if (pinned) {
    return {
      counterId: pinned.id,
      name: counterDisplayName(pinned),
      lifetime: pinned.currentCount ?? 0,
      memberCount: 1 + allTasks.filter((t) => !t.isDeleted && t.sharedCounterId === pinned.id).length,
      countKind: resolveCountKind(pinned),
    };
  }
  if (draft.inlineType !== 'counting' || (draft.countKind ?? 'discrete') === 'duration') return null;
  const action = draft.action.trim();
  const unit = draft.unit.trim();
  return action && unit ? findLinkableCounter({ action, unit }, allTasks) : null;
}

/**
 * The kind an inline counting sub-task is validated, previewed and saved at:
 * its root's when it auto-links (the picker is replaced by a tag), else the
 * picker's.
 *
 * @param draft - The inline sub-task draft.
 * @param allTasks - The library pool.
 * @returns The effective kind.
 */
export function effectiveInlineKind(draft: InlineSubtaskDraft, allTasks: readonly Task[]): CountKind {
  const match = draft.linkDisabled ? null : inlineLinkMatch(draft, allTasks);
  return match ? match.countKind : (draft.countKind ?? 'discrete');
}

/**
 * An inline sub-task's `createCompound` entry. A blank-titled counting
 * sub-task gets the generated "{Action} {Goal} {Unit}" / "{Action} {Xh Ym}"
 * title; an auto-linked one is parsed and saved at its root's kind.
 *
 * @param subtask - The inline draft.
 * @param allTasks - The library pool (auto-link match is re-derived here).
 * @returns The entry.
 */
export function inlineSubtaskToAutoCreate(
  subtask: InlineSubtaskDraft,
  allTasks: readonly Task[],
): CreateCompoundChildEntry {
  if (subtask.inlineType !== 'counting') {
    return { autoCreate: { type: TaskType.NORMAL, title: subtask.title.trim() } };
  }
  const match = subtask.linkDisabled ? null : inlineLinkMatch(subtask, allTasks);
  const kind = effectiveInlineKind(subtask, allTasks);
  const action = subtask.action.trim();
  const unit = countKindNeedsUnit(kind) ? subtask.unit.trim() : '';
  const maxCount = parseCountInput(subtask.maxCountStr, kind) ?? undefined;
  // A sub-task linked to a counter renders the counter's title templates, like every copy of it.
  const linkedRoot = match ? allTasks.find((t) => t.id === match.counterId) : undefined;
  const title =
    subtask.title.trim() ||
    (maxCount === undefined
      ? action
      : linkedRoot
        ? renderCounterTitle(linkedRoot, maxCount)
        : generateCounterTaskTitle(action, maxCount, unit, undefined, kind));
  return {
    autoCreate: {
      type: TaskType.COUNTING,
      title,
      action: action || undefined,
      unit: unit || undefined,
      maxCount,
      ...(kind !== 'discrete' ? { countKind: kind } : {}),
      // "Start fresh" baseline — the source's lifetime at creation.
      sharedCounterId: match ? match.counterId : undefined,
      baseline: match ? match.lifetime : undefined,
    },
  };
}
