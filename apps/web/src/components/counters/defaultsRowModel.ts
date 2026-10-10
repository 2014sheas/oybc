import { COUNTER_GOAL_TIMEFRAMES, parseCountInput, type CounterGoalTimeframe, type CountKind } from '@oybc/shared';

/** The `DefaultsRow` cell labels, shortest timeframe first. */
export const DEFAULTS_ROW_LABELS: Record<CounterGoalTimeframe, string> = {
  daily: 'Daily',
  weekly: 'Weekly',
  monthly: 'Monthly',
  yearly: 'Yearly',
};

/** Field text per core timeframe (`''` / absent = not entered). */
export type DefaultsRowEntered = Partial<Record<CounterGoalTimeframe, string>>;

/**
 * Whether a cell has an entry (any non-blank text, parseable or not).
 *
 * @param entered - The typed texts.
 * @param t - The cell.
 */
export function defaultsCellIsSet(entered: DefaultsRowEntered, t: CounterGoalTimeframe): boolean {
  return (entered[t] ?? '').trim() !== '';
}

/**
 * The cells whose text is non-blank but unparseable at `kind`.
 *
 * @param entered - The typed texts.
 * @param kind - The counter's kind.
 */
export function defaultsRowInvalidCells(entered: DefaultsRowEntered, kind: CountKind): CounterGoalTimeframe[] {
  return COUNTER_GOAL_TIMEFRAMES.filter((t) => defaultsCellIsSet(entered, t) && parseCountInput(entered[t]!, kind) === null);
}

/**
 * The entered goals as numbers (unparseable or blank cells absent).
 *
 * @param entered - The typed texts.
 * @param kind - The counter's kind.
 */
export function defaultsRowGoals(entered: DefaultsRowEntered, kind: CountKind): Partial<Record<CounterGoalTimeframe, number>> {
  const out: Partial<Record<CounterGoalTimeframe, number>> = {};
  for (const t of COUNTER_GOAL_TIMEFRAMES) {
    if (!defaultsCellIsSet(entered, t)) continue;
    const n = parseCountInput(entered[t]!, kind);
    if (n !== null) out[t] = n;
  }
  return out;
}
