import type { StepFormState } from '../progressStepUtils';

/** The inline task types a SubtaskCard can create. Composite sub-composites
 *  can't be built inline — they must already exist in the library. */
export type InlineSubtaskType = 'normal' | 'counting' | 'progress';

/** Existing-mode draft: points at a Task or CompositeTask already in the
 *  library. `selectionType` is derived from which list the id came from
 *  and used purely for the chip badge in Review. */
export interface ExistingSubtaskDraft {
  id: string;
  mode: 'existing';
  selectionType: 'task' | 'composite';
  selectedId: string;
}

/** Inline-mode draft: the user is creating a brand-new Task inside the
 *  composite. On save, the Task row lands in the library AND becomes a
 *  leaf node on the composite. */
export interface InlineSubtaskDraft {
  id: string;
  mode: 'inline';
  inlineType: InlineSubtaskType;
  title: string;
  action: string;
  unit: string;
  maxCountStr: string;
  steps: StepFormState[];
  /** When a user clicks a different type button while the current type
   *  has dirty fields, the click is pending until they confirm switching
   *  (and losing the current fields). Null/undefined = no pending switch. */
  pendingTypeSwitch?: InlineSubtaskType;
}

export type SubtaskDraft = ExistingSubtaskDraft | InlineSubtaskDraft;

/** Result of checking whether a subtask draft is ready to ship as part of
 *  the composite. `message` is a plain-English hint suitable for inline
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
): SubtaskReadiness {
  if (draft.mode === 'existing') {
    if (!draft.selectedId) {
      return { ready: false, message: 'Pick a task or composite from your library.' };
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
      if (!draft.unit.trim()) return { ready: false, message: 'Add a unit (e.g. "miles").' };
      const count = parseInt(draft.maxCountStr, 10);
      if (isNaN(count) || count < 1) {
        return { ready: false, message: 'Add a goal of at least 1.' };
      }
      return { ready: true, message: null };
    }

    case 'progress': {
      if (!draft.title.trim()) return { ready: false, message: 'Add a title for this progress task.' };
      if (draft.steps.length === 0) {
        return { ready: false, message: 'Add at least one step.' };
      }
      for (const step of draft.steps) {
        if (step.type === 'normal' && !step.title.trim()) {
          return { ready: false, message: 'Each normal step needs a title.' };
        }
        if (step.type === 'counting') {
          if (!step.action.trim()) return { ready: false, message: 'Each counting step needs an action.' };
          if (!step.unit.trim()) return { ready: false, message: 'Each counting step needs a unit.' };
          const c = parseInt(step.maxCount, 10);
          if (isNaN(c) || c < 1) {
            return { ready: false, message: 'Each counting step needs a goal of at least 1.' };
          }
        }
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
    case 'progress':
      return (
        titleDirty ||
        draft.steps.some(
          (s) =>
            s.title.trim().length > 0 ||
            s.action.trim().length > 0 ||
            s.unit.trim().length > 0 ||
            s.maxCount.trim().length > 0,
        )
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
  freshSteps: () => StepFormState[],
): InlineSubtaskDraft {
  return {
    id: draft.id,
    mode: 'inline',
    inlineType: nextType,
    title: '',
    action: '',
    unit: '',
    maxCountStr: '',
    steps: nextType === 'progress' ? freshSteps() : [],
    pendingTypeSwitch: undefined,
  };
}
