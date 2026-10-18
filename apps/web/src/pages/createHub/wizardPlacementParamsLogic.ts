/**
 * wizardPlacementParamsLogic.ts — the pure transitions behind
 * `useWizardPlacementParams` (TASK_WINDOW_REWORK slice 3b; the hook is a thin
 * shell, there is no hook renderer in this repo's node Vitest harness).
 */

import type { PlacementParams } from '@oybc/shared';

/**
 * Set (or, with null, clear) one cell's parameters.
 *
 * @param prev - The current map.
 * @param taskId - The cell's task id.
 * @param params - The parameters, or null to clear.
 * @returns The same map when nothing changed, else a new one.
 */
export function withPlacementParamsFor(
  prev: ReadonlyMap<string, PlacementParams>,
  taskId: string,
  params: PlacementParams | null,
): ReadonlyMap<string, PlacementParams> {
  if (params === null && !prev.has(taskId)) return prev;
  const next = new Map(prev);
  if (params === null) next.delete(taskId);
  else next.set(taskId, params);
  return next;
}

/**
 * Drop the parameters of ids that left the selection.
 *
 * @param prev - The current map.
 * @param taskIds - The ids that left.
 * @returns The same map when none had parameters, else a new one.
 */
export function withoutPlacementParams(
  prev: ReadonlyMap<string, PlacementParams>,
  taskIds: readonly string[],
): ReadonlyMap<string, PlacementParams> {
  if (!taskIds.some((id) => prev.has(id))) return prev;
  const next = new Map(prev);
  for (const id of taskIds) next.delete(id);
  return next;
}
