import type { TapLogChip } from '@oybc/shared';

/**
 * A chip's identity across renders: its role, plus the preset's value. The rest
 * chip keeps ONE key as its amount shrinks with every log, so it is never
 * remounted (the old `${index}-${value}` key remounted it on each write).
 */
export function chipKey(chip: TapLogChip): string {
  return chip.role === 'preset' ? `preset-${chip.value}` : chip.role;
}
