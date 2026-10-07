import type { CountKind } from '@oybc/shared';

/**
 * The soft keyboard a kind's field asks for: decimal only for continuous
 * (iOS Safari then shows the locale's separator key).
 *
 * @param kind - The counter's kind.
 * @returns The `inputMode` attribute value.
 */
export function goalEntryInputMode(kind: CountKind): 'numeric' | 'decimal' {
  return kind === 'continuous' ? 'decimal' : 'numeric';
}
