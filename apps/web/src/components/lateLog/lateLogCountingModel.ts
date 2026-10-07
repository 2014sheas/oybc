import {
  countUnitSuffix,
  formatCount,
  formatCountWithUnit,
  lateLogChipAmounts,
  parseCountInput,
  type CountKind,
} from '@oybc/shared';

/**
 * The first chip — what the closed-board late-log sheet opens on.
 *
 * @param kind - The counter's kind.
 * @param goal - The square's goal.
 * @returns The first chip amount.
 */
export function initialLateLogAmount(kind: CountKind, goal: number): number {
  return lateLogChipAmounts(kind, goal)[0];
}

/**
 * Everything the closed-board COUNTING body renders (docs/COUNTER_KINDS.md §5 B3).
 * Discrete keeps `+1 · +2 · +5` and a plain `Log`; Continuous / Duration get goal
 * chips and `Log +{amount}{ unit}`. iOS twin: `LateLogCountingCopy`.
 *
 * @param a - Kind, goal, current count, unit and the staged selection / custom draft.
 * @returns The chips, readout strings, amount to commit (null when invalid), button label and canLog.
 */
export function lateLogCountingModel(a: {
  kind: CountKind;
  goal: number;
  count: number;
  unit: string;
  selected: number;
  customOpen: boolean;
  customDraft: string;
}): {
  chips: { amount: number; label: string }[];
  readout: { count: string; max: string; unit: string };
  amount: number | null;
  buttonLabel: string;
  canLog: boolean;
} {
  const amount = a.customOpen ? parseCountInput(a.customDraft, a.kind) : a.selected;
  return {
    chips: lateLogChipAmounts(a.kind, a.goal).map((v) => ({ amount: v, label: `+${formatCount(v, a.kind)}` })),
    readout: {
      count: formatCount(a.count, a.kind),
      max: formatCount(a.goal, a.kind),
      unit: countUnitSuffix(a.kind, a.unit).trim(),
    },
    amount,
    buttonLabel: a.kind === 'discrete' || amount === null ? 'Log' : `Log +${formatCountWithUnit(amount, a.kind, a.unit)}`,
    canLog: amount !== null,
  };
}
