/**
 * poolPickerLogic.ts — `PoolPickerSheet`'s own tiny decision logic,
 * extracted for direct unit coverage (this repo's Vitest harness is
 * `environment: 'node'` with no component-render support — see
 * `poolPullLogic.ts`'s docstring for the established precedent of
 * extracting pure functions from otherwise-untestable UI logic).
 *
 * Task Pools + Recurring Boards Rework, P7, docs/POOLS_RECURRING.md
 * §Surfaces item 10 ("+ Build a new pool…" round-trips back to the
 * launching context with the new pool selected).
 */

/**
 * Whether "+ Build a new pool…" should auto-select the pool it just
 * created. Guards against double-toggling a pool that's somehow already
 * in the caller's selection (defensive — shouldn't occur for a
 * freshly-minted id, but a toggle function is not idempotent, so calling
 * it unconditionally would silently DESELECT an already-selected pool
 * instead of leaving it selected).
 */
export function shouldSelectAfterPoolCreated(
  createdPoolId: string,
  selectedPoolIds: readonly string[],
): boolean {
  return !selectedPoolIds.includes(createdPoolId);
}
