import { Timeframe } from '@oybc/shared';

/**
 * Timeframe accent-dot background color for shared-counter rows.
 * daily=gold · weekly=blue · monthly=green · yearly=red (handoff §Design Tokens,
 * matches iOS `Timeframe.risoColor`). Anything else (custom/indefinite/none) → muted.
 */
export function timeframeDotColor(tf: Timeframe | null): string {
  switch (tf) {
    case Timeframe.DAILY:
      return 'var(--riso-gold)';
    case Timeframe.WEEKLY:
      return 'var(--riso-blue)';
    case Timeframe.MONTHLY:
      return 'var(--riso-green)';
    case Timeframe.YEARLY:
      return 'var(--riso-red)';
    default:
      return 'var(--riso-muted)';
  }
}
