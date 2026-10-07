import {
  formatCountWithUnit,
  logPillLabel,
  logPillOpensDetail,
  type SharedCounterGroup,
} from '@oybc/shared';

/**
 * The "+ Log" pill's label, accessible name and action (docs/COUNTER_KINDS.md §5).
 * A never-logged Continuous / Duration counter has no amount to log, so its
 * pill opens Counter Detail instead.
 */
export function ledgerPill(
  group: Pick<SharedCounterGroup, 'name' | 'unit' | 'countKind' | 'defaultLogAmount'>,
): { label: string; ariaLabel: string; opensDetail: boolean; amount: number } {
  const opensDetail = logPillOpensDetail(group.countKind, group.defaultLogAmount);
  const amount = group.defaultLogAmount ?? 1;
  return {
    label: logPillLabel(group.countKind, group.defaultLogAmount),
    ariaLabel: opensDetail
      ? `Log ${group.name}`
      : `Log ${formatCountWithUnit(amount, group.countKind, group.unit)} for ${group.name}`,
    opensDetail,
    amount,
  };
}
