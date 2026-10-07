/**
 * Counter kinds — the single owner of counting-value maths
 * (docs/COUNTER_KINDS.md §3). Every kernel, write path and validator that
 * touches a goal / count / delta / baseline / default log amount /
 * member-rule target goes through these helpers. Swift twin:
 * `apps/ios/OYBC/Helpers/CountValue.swift`, pinned by countValueVectors.json.
 */

/** A counting task's kind. Absent on a stored row ⇒ `'discrete'`. */
export type CountKind = 'discrete' | 'continuous' | 'duration';

/** Every kind, in picker order. */
export const COUNT_KINDS: readonly CountKind[] = ['discrete', 'continuous', 'duration'];

/**
 * A task's effective kind.
 *
 * @param task - Anything carrying an optional `countKind`.
 * @returns The kind, defaulting to `'discrete'` when absent or null.
 */
export function resolveCountKind(task: { countKind?: CountKind | null }): CountKind {
  return task.countKind ?? 'discrete';
}

/**
 * Whether a kind counts in whole units (discrete counts, duration minutes).
 *
 * @param kind - The kind.
 * @returns True for `'discrete'` and `'duration'`.
 */
export function isWholeCountKind(kind: CountKind): boolean {
  return kind !== 'continuous';
}

/**
 * Rounds to 2 decimal places, half away from zero. The `1e-7` nudge absorbs
 * binary representation error (1.005 is stored as 1.00499…), and dividing an
 * integer by 100 yields the same nearest double in JS and Swift.
 *
 * @param x - Any finite number.
 * @returns `x` at 0.01 precision; `-0` normalised to `0`.
 */
export function quantizeCount(x: number): number {
  const r = Math.round(Math.abs(x) * 100 + 1e-7) / 100;
  if (r === 0) return 0;
  return x < 0 ? -r : r;
}

/**
 * Whether `x` is a storable counting value: finite and already at 2dp.
 *
 * @param x - The candidate.
 * @returns True when `quantizeCount(x) === x`.
 */
export function isQuantizedCount(x: number): boolean {
  return Number.isFinite(x) && quantizeCount(x) === x;
}

/**
 * The displayed / compared count for a window: low-clamped at 0, quantized,
 * and rounded half-up for whole kinds (a task switched to discrete may hold
 * fractional history — D4 rounds the SUM, never each event).
 *
 * @param sum - Raw signed delta sum.
 * @param kind - The task's kind.
 * @returns The finalised count.
 */
export function finalizeWindowCount(sum: number, kind: CountKind): number {
  const q = quantizeCount(Math.max(0, sum));
  return isWholeCountKind(kind) ? Math.floor(q + 0.5) : q;
}

/**
 * Display text for a counting value. Whole kinds show whole numbers;
 * continuous trims trailing zeros; duration (minutes) renders `Xh Ym`.
 * No digit grouping and always Latin digits (matches the pre-feature raw
 * interpolation); only the decimal separator follows the locale.
 *
 * @param value - The value (minutes for duration).
 * @param kind - The task's kind.
 * @param locale - BCP 47 locale; defaults to the runtime locale.
 * @returns The formatted string.
 */
export function formatCount(value: number, kind: CountKind, locale?: string): string {
  if (kind === 'duration') {
    const minutes = Math.max(0, Math.floor(value + 0.5));
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    if (h === 0) return `${m}m`;
    return m === 0 ? `${h}h` : `${h}h ${m}m`;
  }
  const digits = kind === 'continuous' ? 2 : 0;
  const v = kind === 'continuous' ? quantizeCount(value) : Math.floor(quantizeCount(value) + 0.5);
  return new Intl.NumberFormat(locale, {
    minimumFractionDigits: 0,
    maximumFractionDigits: digits,
    useGrouping: false,
    numberingSystem: 'latn',
  }).format(v);
}

/**
 * The string a text field is SEEDED with and later re-parsed from: locale
 * fixed to en-US (ASCII digits, `.` separator), no grouping.
 *
 * @param value - The value (minutes for duration).
 * @param kind - The task's kind.
 * @returns The locale-independent formatted string.
 */
export function formatCountForInput(value: number, kind: CountKind): string {
  return formatCount(value, kind, 'en-US');
}

/**
 * Whether a counter may change kind (D4): discrete ⇄ continuous only.
 *
 * @param from - Current kind.
 * @param to - Requested kind.
 * @returns True only for a real discrete ⇄ continuous change.
 */
export function canSwitchCountKind(from: CountKind, to: CountKind): boolean {
  return from !== to && from !== 'duration' && to !== 'duration';
}

/**
 * The field patch a kind switch writes, or `null` when the switch is refused.
 * Switching to a whole kind rounds the goal and default amount (min 1).
 * Absent / null inputs stay absent in the patch.
 *
 * @param fields - The task's current goal / default log amount.
 * @param from - Current kind.
 * @param to - Requested kind.
 * @returns The patch (may be `{}`), or `null`.
 */
export function planCountKindSwitch(
  fields: { maxCount?: number | null; defaultLogAmount?: number | null },
  from: CountKind,
  to: CountKind,
): { maxCount?: number; defaultLogAmount?: number } | null {
  if (!canSwitchCountKind(from, to)) return null;
  const conv = (v: number): number =>
    isWholeCountKind(to) ? Math.max(1, Math.floor(quantizeCount(v) + 0.5)) : quantizeCount(v);
  const patch: { maxCount?: number; defaultLogAmount?: number } = {};
  if (fields.maxCount != null) patch.maxCount = conv(fields.maxCount);
  if (fields.defaultLogAmount != null) patch.defaultLogAmount = conv(fields.defaultLogAmount);
  return patch;
}

/**
 * The granularity of a member-rule target / vary bound for a kind.
 *
 * @param kind - The kind.
 * @returns 1 for whole kinds, 0.1 for continuous.
 */
export function countTargetStep(kind: CountKind): number {
  return isWholeCountKind(kind) ? 1 : 0.1;
}

// ── Member-rule step rounding (docs/COUNTER_KINDS.md §3) ────────────────────
// The pro-rate / vary / clamp steps in memberRules.ts round to the kind's
// target step. Whole kinds take the EXACT pre-feature integer ops (no
// quantize first — 1/366 must still ceil to 1, and every discrete vector
// stays where it was); only continuous steps in tenths, quantizing the tenths
// count first so a representation-error product like 6.1 × 10 = 60.999…
// reads as 61 before the ceil/round/floor. The `1e-9` nudges keep an exact
// tenth on itself. Inputs are non-negative (targets, goals). Swift twins in
// CountValue.swift run the identical arithmetic.

/**
 * Ceil to the kind's target step (1, or 0.1 for continuous).
 *
 * @param x - A non-negative value.
 * @param kind - The task's kind.
 * @returns The smallest step multiple ≥ `x`.
 */
export function ceilToCountStep(x: number, kind: CountKind): number {
  if (isWholeCountKind(kind)) return Math.ceil(x);
  return quantizeCount(Math.ceil(quantizeCount(x * 10) - 1e-9) / 10);
}

/**
 * Round half-up to the kind's target step (1, or 0.1 for continuous).
 *
 * @param x - A non-negative value.
 * @param kind - The task's kind.
 * @returns The nearest step multiple, ties upward.
 */
export function roundToCountStep(x: number, kind: CountKind): number {
  if (isWholeCountKind(kind)) return Math.round(x);
  return quantizeCount(Math.round(quantizeCount(x * 10) + 1e-9) / 10);
}

/**
 * Floor to the kind's target step (1, or 0.1 for continuous).
 *
 * @param x - A non-negative value.
 * @param kind - The task's kind.
 * @returns The largest step multiple ≤ `x`.
 */
export function floorToCountStep(x: number, kind: CountKind): number {
  if (isWholeCountKind(kind)) return Math.floor(x);
  return quantizeCount(Math.floor(quantizeCount(x * 10) + 1e-9) / 10);
}
