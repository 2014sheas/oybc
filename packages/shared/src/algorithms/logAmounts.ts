/**
 * Counter kinds — the single owner of LOG-AMOUNT choices (docs/COUNTER_KINDS.md
 * §5): chip sets per surface, the pre-selected amount, the one-tap amount and
 * the "+ Log" pill label. Swift twin: `apps/ios/OYBC/Helpers/CounterLogAmount.swift`,
 * pinned by `tests/fixtures/logAmountVectors.json`.
 */
import { countTargetStep, formatCount, quantizeCount, roundToCountStep, type CountKind } from './countValue';

/** One chip; `value: null` is the custom `#` chip. */
export interface LogChip {
  value: number | null;
  label: string;
}

const FIXED: Record<CountKind, readonly number[]> = {
  discrete: [1, 10, 25],
  continuous: [0.5, 1, 5],
  duration: [15, 30, 60],
};

const CUSTOM: LogChip = { value: null, label: '#' };

/**
 * Hub / Counter Detail presets (no single goal there).
 *
 * @param kind - The counter's kind.
 * @returns The fixed preset amounts.
 */
export function fixedLogChipAmounts(kind: CountKind): readonly number[] {
  return FIXED[kind];
}

/**
 * ¼ · ½ · goal — stepped to the kind (0.1 / 1 minute), floored at one step,
 * de-duplicated; the goal itself is never re-stepped. A goal <= 0 falls back
 * to the fixed set.
 *
 * @param goal - The square's goal.
 * @param kind - The counter's kind.
 * @returns The chip amounts.
 */
export function goalChipAmounts(goal: number, kind: CountKind): number[] {
  if (!(goal > 0)) return [...FIXED[kind]];
  const step = countTargetStep(kind);
  const values = [0.25, 0.5].map((f) => Math.max(step, roundToCountStep(goal * f, kind)));
  values.push(goal);
  return values.filter((v, i) => values.indexOf(v) === i);
}

/**
 * The stepper sheet / detail modal row. Discrete keeps `+1 · +10 · #`.
 *
 * @param kind - The counter's kind.
 * @param goal - The square's goal.
 * @returns The chips, ending in the custom `#`.
 */
export function boardSheetChips(kind: CountKind, goal: number): LogChip[] {
  if (kind === 'discrete') return [{ value: 1, label: '+1' }, { value: 10, label: '+10' }, CUSTOM];
  return [...goalChipAmounts(goal, kind).map((v) => ({ value: v, label: formatCount(v, kind) })), CUSTOM];
}

/**
 * The Counter Detail Log card / hub row.
 *
 * @param kind - The counter's kind.
 * @returns The fixed chips, ending in the custom `#`.
 */
export function hubChips(kind: CountKind): LogChip[] {
  return [...FIXED[kind].map((v) => ({ value: v, label: formatCount(v, kind) })), CUSTOM];
}

/** One tap-to-log chip: a preset, the rest of the window's goal, or "Other…". */
export interface TapLogChip {
  /** `null` on the "Other…" chip. */
  value: number | null;
  label: string;
  role: 'preset' | 'rest' | 'other';
}

/** Ceil to the kind's step, so the rest chip always reaches the goal. */
function ceilToCountStep(x: number, kind: CountKind): number {
  if (kind !== 'continuous') return Math.ceil(x - 1e-9);
  return quantizeCount(Math.ceil(quantizeCount(x * 10) - 1e-9) / 10);
}

/** "+5h30" / "+45m" / "+2h" — the duration rest chip's compact label. */
function compactDurationLabel(minutes: number): string {
  const total = Math.max(0, Math.round(minutes));
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h === 0) return `${m}m`;
  return m === 0 ? `${h}h` : `${h}h${String(m).padStart(2, '0')}`;
}

/**
 * The one-gesture chip row (docs/TASK_DETAIL_REDESIGN.md E3): the kind's
 * fixed presets (`fixedLogChipAmounts`), then the rest of this window's goal
 * (`+N ✓`, ceiled to the kind's step) when it is positive and not already a
 * preset, then "Other…". No goal (Counter Detail) → no rest chip.
 *
 * @param kind - The counter's family kind.
 * @param goal - The square's goal in this window, if any.
 * @param windowedCount - The windowed count the rest is measured from.
 * @returns The chips, ending in "Other…".
 */
export function tapLogChips(kind: CountKind, goal?: number | null, windowedCount = 0): TapLogChip[] {
  const chips: TapLogChip[] = FIXED[kind].map((v) => ({ value: v, label: `+${formatCount(v, kind)}`, role: 'preset' }));
  if (goal != null && goal > 0) {
    const rest = ceilToCountStep(goal - windowedCount, kind);
    if (rest > 0 && !FIXED[kind].includes(rest)) {
      const text = kind === 'duration' ? compactDurationLabel(rest) : formatCount(rest, kind);
      chips.push({ value: rest, label: `+${text} ✓`, role: 'rest' });
    }
  }
  chips.push({ value: null, label: 'Other…', role: 'other' });
  return chips;
}

/**
 * Closed-board late-log presets. Discrete keeps `+1 · +2 · +5`.
 *
 * @param kind - The counter's kind.
 * @param goal - The square's goal.
 * @returns The preset amounts.
 */
export function lateLogChipAmounts(kind: CountKind, goal: number): number[] {
  return kind === 'discrete' ? [1, 2, 5] : goalChipAmounts(goal, kind);
}

function presets(chips: LogChip[]): number[] {
  return chips.flatMap((c) => (c.value === null ? [] : [c.value]));
}

/**
 * What a sheet opens on. A remembered default matching a chip selects it; for
 * Continuous / Duration any other default shows on `#`; Discrete keeps
 * `initialChipAmount` (a 1 / 10 / 25 default, else 1); with nothing
 * remembered, the first chip.
 *
 * @param kind - The counter's kind.
 * @param chips - The sheet's chips.
 * @param defaultLogAmount - The remembered last-used amount.
 * @returns The selected amount and whether it rides on the custom chip.
 */
export function initialLogSelection(
  kind: CountKind,
  chips: LogChip[],
  defaultLogAmount: number | null | undefined,
): { amount: number; isCustom: boolean } {
  const p = presets(chips);
  if (defaultLogAmount != null && p.includes(defaultLogAmount)) {
    return { amount: defaultLogAmount, isCustom: false };
  }
  if (kind === 'discrete') {
    const keep = defaultLogAmount != null && FIXED.discrete.includes(defaultLogAmount);
    return { amount: keep ? (defaultLogAmount as number) : 1, isCustom: false };
  }
  if (defaultLogAmount != null) return { amount: defaultLogAmount, isCustom: true };
  return { amount: p[0] ?? countTargetStep(kind), isCustom: false };
}

/**
 * The one-tap / long-press "+ Add {last}" amount.
 *
 * @param kind - The counter's kind.
 * @param chips - The sheet's chips.
 * @param defaultLogAmount - The remembered last-used amount.
 * @returns The amount to log.
 */
export function quickLogAmount(
  kind: CountKind,
  chips: LogChip[],
  defaultLogAmount: number | null | undefined,
): number {
  if (defaultLogAmount != null) return defaultLogAmount;
  return kind === 'discrete' ? 1 : (presets(chips)[0] ?? countTargetStep(kind));
}

/**
 * The selected custom chip's label — "#3.1", "#1h 30m".
 *
 * @param amount - The custom amount.
 * @param kind - The counter's kind.
 * @returns The label.
 */
export function customChipLabel(amount: number, kind: CountKind): string {
  return `#${formatCount(amount, kind)}`;
}

/**
 * "+ Log" / "+ Log 3.1" / "+ Log 30m".
 *
 * @param kind - The counter's kind.
 * @param defaultLogAmount - The remembered last-used amount.
 * @returns The pill label.
 */
export function logPillLabel(kind: CountKind, defaultLogAmount: number | null | undefined): string {
  if (kind === 'discrete' || defaultLogAmount == null) return '+ Log';
  return `+ Log ${formatCount(defaultLogAmount, kind)}`;
}

/**
 * A never-logged Continuous / Duration counter's pill opens Counter Detail
 * instead of logging.
 *
 * @param kind - The counter's kind.
 * @param defaultLogAmount - The remembered last-used amount.
 * @returns Whether the pill opens detail.
 */
export function logPillOpensDetail(kind: CountKind, defaultLogAmount: number | null | undefined): boolean {
  return kind !== 'discrete' && defaultLogAmount == null;
}
