import {
  countKindNeedsUnit,
  generateCounterTaskTitle,
  parseCountInput,
  resolveCountKind,
  type CountKind,
  type Task,
} from '@oybc/shared';
import type { LinkedCounterInput } from '../../components/wizard/CountingTemplatePicker';

/**
 * The kind a counting create saves (docs/COUNTER_KINDS.md §5, D5): an
 * auto-linking create follows the matched root; otherwise the picker.
 *
 * @param picked - The kind the picker shows.
 * @param link - The auto-link state, or null when there is no match.
 * @returns The kind the create is validated, previewed and saved at.
 */
export function effectiveCountingKind(
  picked: CountKind,
  link: { linked: boolean; countKind: CountKind } | null,
): CountKind {
  return link?.linked ? link.countKind : picked;
}

/**
 * The Goal field's validation message at a kind.
 *
 * @param goalText - The field text.
 * @param kind - The kind it is parsed at.
 * @returns The message, or undefined when valid.
 */
export function countingGoalError(goalText: string, kind: CountKind): string | undefined {
  if (goalText.trim() === '') return 'Goal is required';
  if (parseCountInput(goalText, kind) !== null) return undefined;
  if (kind === 'discrete') return 'Goal must be a positive integer';
  return kind === 'continuous'
    ? 'Goal must be a number above zero with up to 2 decimals'
    : 'Goal must be a duration above zero';
}

/**
 * The live "Title:" preview.
 *
 * @returns The title, or null until Action, Goal (and Unit, unless Duration) are valid.
 */
export function countingTitlePreview(
  action: string,
  goalText: string,
  unit: string,
  kind: CountKind,
): string | null {
  const a = action.trim();
  const u = unit.trim();
  const goal = parseCountInput(goalText, kind);
  if (!a || goal === null || (countKindNeedsUnit(kind) && !u)) return null;
  return generateCounterTaskTitle(a, goal, countKindNeedsUnit(kind) ? u : '', undefined, kind);
}

/**
 * The auto-link create input, with the goal parsed at the SOURCE's kind
 * (Review Focus 3 — the picker may have shown another kind).
 *
 * @returns The input, or null when the goal is invalid at the root kind.
 */
export function buildLinkedCreateInput(args: {
  source: Task;
  goalText: string;
  title: string;
  action: string;
  unit: string;
  baseline: number;
}): LinkedCounterInput | null {
  const kind = resolveCountKind(args.source);
  const maxCount = parseCountInput(args.goalText, kind);
  if (maxCount === null) return null;
  const title =
    args.title.trim() ||
    generateCounterTaskTitle(args.action.trim(), maxCount, args.unit.trim(), undefined, kind);
  return { source: args.source, maxCount, title, baselineMode: 'startFromZero', baseline: args.baseline };
}
