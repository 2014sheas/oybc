import {
  COUNT_KIND_LABELS,
  formatCount,
  formatCountForInput,
  parseCountInput,
  planCountKindSwitch,
  type CountKind,
} from '@oybc/shared';
import type { KindSwitchPreview } from '../../db/operations/countKindSwitch';

/**
 * kindSwitchModel.ts — copy + goal rounding behind the Continuous → Discrete
 * confirm (docs/COUNTER_KINDS.md §5). Swift twin: `KindSwitchCopy` in
 * `KindSwitchConfirmView.swift`.
 */

/**
 * D4 / §5: only the rounding direction confirms.
 *
 * @param from - The kind the editor shows now.
 * @param to - The kind the user picked.
 * @returns True only for Continuous → Discrete.
 */
export function needsKindSwitchConfirm(from: CountKind, to: CountKind): boolean {
  return from === 'continuous' && to === 'discrete';
}

/**
 * The confirm's copy — the one consequence body the no-explanatory-copy rule allows.
 *
 * @param p - The switch preview.
 * @returns Heading, the before → after rows, and the consequence body.
 */
export function kindSwitchConfirmLines(p: KindSwitchPreview): {
  title: string;
  rows: [string, string][];
  body: string;
} {
  const family =
    p.linkedCount === 0 ? '' : ` Follows on ${p.linkedCount} linked square${p.linkedCount === 1 ? '' : 's'}.`;
  return {
    title: `Switch to ${COUNT_KIND_LABELS[p.to]}?`,
    rows: [
      [p.titleBefore, p.titleAfter],
      [`${formatCount(p.loggedBefore, p.from)} logged`, `${formatCount(p.loggedAfter, p.to)} logged`],
    ],
    body: `Switching back restores the exact values.${family}`,
  };
}

/**
 * The Goal field's text after a confirmed switch (rounded for a whole kind).
 *
 * @param goalText - The Goal field's current text, typed at `from`.
 * @param from - The kind the text was typed at.
 * @param to - The confirmed kind.
 * @returns The rounded goal text, or `goalText` unchanged when it does not parse.
 */
export function switchedGoalText(goalText: string, from: CountKind, to: CountKind): string {
  const goal = parseCountInput(goalText, from);
  if (goal === null) return goalText;
  const patch = planCountKindSwitch({ maxCount: goal }, from, to);
  return patch?.maxCount != null ? formatCountForInput(patch.maxCount, to) : goalText;
}
