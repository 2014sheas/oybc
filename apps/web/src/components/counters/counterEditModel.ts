import {
  changedCounterSettingsKeys,
  counterSettingsDraftFromRoot,
  isAutoCounterTitle,
  planCountKindSwitch,
  renderCounterTitle,
  resolveCountKind,
  storedCounterSettings,
  storedCounterSettingsFromDraft,
  type CounterSettingsDraft,
  type CountKind,
  type StoredCounterSettings,
  type Task,
} from '@oybc/shared';
import type { TaskEditSubmit } from '../../db/operations';

/**
 * counterEditModel.ts — the pure half of the counter sheet's EDIT mode
 * (`CreateCounterSheet` with `root`). A counter is edited through the
 * counter sheet, never the task editor (owner rule 2026-10-09): the same
 * fields as create — Kind, "What are you counting?" (unit), "Task verb"
 * (action), and the shared counter settings (docs/SHARED_COUNTER_SETTINGS.md
 * §1: name, `#N` title templates, timeframe defaults) — saved through the
 * Task Detail write (`saveTaskEdit`), so #575 root → copy propagation and the
 * D5 family kind switch apply unchanged. Swift twin: `CounterEditModel`
 * (`Helpers/CounterEditModel.swift`).
 */

/** The sheet's editable fields. */
export interface CounterEditDraft {
  /** "Task verb" — stored as `action`; required (the sheet gates Save on it). */
  verb: string;
  /** "What are you counting?" — stored as `unit`. */
  noun: string;
  kind: CountKind;
  /** The optional settings as typed (`''` / absent = unset, the default shows dimmed). */
  settings: CounterSettingsDraft;
}

/**
 * The sheet's fields seeded from the counter's root.
 *
 * @param root - The counter's root task.
 * @returns The prefilled draft.
 */
export function seedCounterEditDraft(root: Task): CounterEditDraft {
  return {
    verb: root.action ?? '',
    noun: root.unit ?? '',
    kind: resolveCountKind(root),
    settings: counterSettingsDraftFromRoot(root),
  };
}

/**
 * The `saveTaskEdit` submit for a draft: action / unit, `countKind` only when
 * it changed, every shared counter setting whose stored value changed (a
 * present-`undefined` key clears it — D3, absent = default), and the title —
 * re-rendered from the new fields through the POST-edit name / templates, at
 * the goal the kind switch leaves, when the root's title is auto, else kept
 * verbatim. Never a type, description or goal.
 *
 * @param root - The counter's root task (stored).
 * @param draft - The sheet's fields.
 * @returns The submit for `saveTaskEdit(root.id, …)`.
 */
export function counterEditSubmit(root: Task, draft: CounterEditDraft): TaskEditSubmit {
  const storedKind = resolveCountKind(root);
  const action = draft.verb.trim();
  const unit = draft.noun.trim();
  const kindChanged = draft.kind !== storedKind;
  const goal = kindChanged
    ? (planCountKindSwitch({ maxCount: root.maxCount }, storedKind, draft.kind)?.maxCount ?? root.maxCount)
    : root.maxCount;
  const after = storedCounterSettingsFromDraft({ action, unit, countKind: draft.kind }, draft.settings);
  const settingsPatch: Partial<StoredCounterSettings> = {};
  for (const key of changedCounterSettingsKeys(storedCounterSettings(root), after)) {
    // A changed key is present even when `after` lacks it — present-`undefined` = clear.
    (settingsPatch as Record<string, unknown>)[key] = after[key];
  }
  const auto = isAutoCounterTitle(root.title, root.action ?? '', root.maxCount, root.unit ?? '', storedKind, root);
  const title = auto
    ? renderCounterTitle(
        {
          ...root,
          action,
          unit,
          countKind: draft.kind,
          counterName: after.counterName,
          titleTemplateSingular: after.titleTemplateSingular,
          titleTemplatePlural: after.titleTemplatePlural,
        },
        goal,
      )
    : root.title;
  return { title, action, unit, ...(kindChanged ? { countKind: draft.kind } : {}), ...settingsPatch };
}

/**
 * Whether the draft renames the counter (its verb / noun identity) — only
 * then does the sheet check for an established counter of that name.
 *
 * @param root - The counter's root task.
 * @param draft - The sheet's verb / noun.
 */
export function counterEditIdentityChanged(root: Task, draft: Pick<CounterEditDraft, 'verb' | 'noun'>): boolean {
  return draft.verb.trim() !== (root.action ?? '').trim() || draft.noun.trim() !== (root.unit ?? '').trim();
}

/**
 * The dedupe pool for a rename: every task except the counter's own family
 * (the root and the rows linking to it), so a counter never matches itself.
 *
 * @param root - The counter's root task.
 * @param tasks - The user's live tasks.
 */
export function counterEditDedupePool(root: Task, tasks: readonly Task[]): Task[] {
  return tasks.filter((t) => t.id !== root.id && t.sharedCounterId !== root.id);
}
