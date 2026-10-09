import {
  generateCounterTaskTitle,
  isAutoCounterTitle,
  planCountKindSwitch,
  resolveCountKind,
  type CountKind,
  type Task,
} from '@oybc/shared';
import type { TaskEditSubmit } from '../../db/operations';

/**
 * counterEditModel.ts — the pure half of the counter sheet's EDIT mode
 * (`CreateCounterSheet` with `root`). A counter is edited through the
 * counter sheet, never the task editor (owner rule 2026-10-09): the same
 * fields as create — Kind, "What are you counting?" (unit), "Task verb"
 * (action) — saved through the Task Detail write (`saveTaskEdit`), so #575
 * root → copy propagation and the D5 family kind switch apply unchanged.
 * Swift twin: `CounterEditModel` (`Helpers/CounterEditModel.swift`).
 */

/** The sheet's editable fields. */
export interface CounterEditDraft {
  /** "Task verb" — stored as `action`; blank submits as "Do". */
  verb: string;
  /** "What are you counting?" — stored as `unit`. */
  noun: string;
  kind: CountKind;
}

/** Fallback verb for a blank "Task verb" (the create sheet's rule). */
const DEFAULT_VERB = 'Do';

/**
 * The sheet's fields seeded from the counter's root.
 *
 * @param root - The counter's root task.
 * @returns The prefilled draft.
 */
export function seedCounterEditDraft(root: Task): CounterEditDraft {
  return { verb: root.action ?? '', noun: root.unit ?? '', kind: resolveCountKind(root) };
}

/**
 * The `saveTaskEdit` submit for a draft: action / unit, `countKind` only when
 * it changed, and the title — regenerated from the new fields (at the goal
 * the kind switch leaves) when the root's title is auto, else kept verbatim.
 * Never a type, description or goal.
 *
 * @param root - The counter's root task (stored).
 * @param draft - The sheet's fields.
 * @returns The submit for `saveTaskEdit(root.id, …)`.
 */
export function counterEditSubmit(root: Task, draft: CounterEditDraft): TaskEditSubmit {
  const storedKind = resolveCountKind(root);
  const action = draft.verb.trim() || DEFAULT_VERB;
  const unit = draft.noun.trim();
  const kindChanged = draft.kind !== storedKind;
  const goal = kindChanged
    ? (planCountKindSwitch({ maxCount: root.maxCount }, storedKind, draft.kind)?.maxCount ?? root.maxCount)
    : root.maxCount;
  const auto = isAutoCounterTitle(root.title, root.action ?? '', root.maxCount, root.unit ?? '', storedKind);
  const title = auto ? generateCounterTaskTitle(action, goal, unit, undefined, draft.kind) : root.title;
  return { title, action, unit, ...(kindChanged ? { countKind: draft.kind } : {}) };
}

/**
 * Whether the draft renames the counter (its verb / noun identity) — only
 * then does the sheet check for an established counter of that name.
 *
 * @param root - The counter's root task.
 * @param draft - The sheet's fields.
 */
export function counterEditIdentityChanged(root: Task, draft: CounterEditDraft): boolean {
  const seed = seedCounterEditDraft(root);
  return (draft.verb.trim() || DEFAULT_VERB) !== (seed.verb.trim() || DEFAULT_VERB) || draft.noun.trim() !== seed.noun.trim();
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
