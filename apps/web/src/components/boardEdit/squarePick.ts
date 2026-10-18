import type { PlacementParams } from '@oybc/shared';

/**
 * The picker's buffer of a counter root's placement parameters (reported by
 * the quick-add row just BEFORE the pick lands) and the pick it resolves to.
 * Pure so the order contract is unit-testable without a DOM.
 */
export type PlacementBuffer = Map<string, PlacementParams | null>;

/**
 * Resolve a picked existing task into a pick, consuming its buffered parameters.
 *
 * @param buffer - The sheet's buffer.
 * @param taskId - The picked task.
 * @returns `{ taskId, placement? }` — `placement` only when parameters were reported.
 */
export function takeExistingPick(
  buffer: PlacementBuffer,
  taskId: string,
): { taskId: string; placement?: PlacementParams } {
  const placement = buffer.get(taskId) ?? undefined;
  buffer.delete(taskId);
  return { taskId, ...(placement ? { placement } : {}) };
}
