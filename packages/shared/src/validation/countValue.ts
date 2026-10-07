import { z } from 'zod';
import { isQuantizedCount, isWholeCountKind, resolveCountKind, type CountKind } from '../algorithms/countValue';

/**
 * Zod pieces for counter kinds (docs/COUNTER_KINDS.md §3). Lives outside
 * schemas.ts (near its 1000-line cap) — the `boardSource.ts` precedent.
 */
export const CountKindSchema = z.enum(['discrete', 'continuous', 'duration']);

const QUANTIZED_MSG = 'must be a finite number with at most 2 decimal places';

/** A strictly positive 2dp counting value (goal, default log amount, target). */
export const positiveCount = () => z.number().positive().refine(isQuantizedCount, { message: QUANTIZED_MSG });

/** A non-negative 2dp counting value (count cache, baseline). */
export const nonNegativeCount = () => z.number().min(0).refine(isQuantizedCount, { message: QUANTIZED_MSG });

/** A valid increment delta: non-zero and 2dp. */
export const isValidCountDelta = (d: number): boolean => d !== 0 && isQuantizedCount(d);

/**
 * Whole kinds store whole goals / default amounts. `currentCount` is a cache
 * that may hold fractional history after a switch (D4), so it is not checked.
 */
export const countFieldsMatchKind = (t: {
  countKind?: CountKind | null;
  maxCount?: number | null;
  defaultLogAmount?: number | null;
}): boolean => {
  if (!isWholeCountKind(resolveCountKind(t))) return true;
  const whole = (v: number | null | undefined) => v == null || Number.isInteger(v);
  return whole(t.maxCount) && whole(t.defaultLogAmount);
};
