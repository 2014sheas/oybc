/**
 * wizardPlacementParamsLogic.ts — the pure transitions behind
 * `useWizardPlacementParams` (TASK_WINDOW_REWORK slice 3b; the hook is a thin
 * shell, there is no hook renderer in this repo's node Vitest harness).
 */

import type { ManualTaskTarget, PlacementParams } from '@oybc/shared';

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

/**
 * Which placement-parameter entries the person TYPED (a hand-typed goal), as
 * opposed to an automatic window default a quick-add stamped. Only typed
 * entries are frozen into a repeating board's `manualTaskTargets`; an
 * automatic default is re-evaluated by the planner at every spawn.
 *
 * @param prev - The current typed ids.
 * @param taskId - The cell's task id.
 * @param typed - True when the entry now in the map was typed.
 * @returns The same set when nothing changed, else a new one.
 */
export function withTypedPlacementFor(
  prev: ReadonlySet<string>,
  taskId: string,
  typed: boolean,
): ReadonlySet<string> {
  if (prev.has(taskId) === typed) return prev;
  const next = new Set(prev);
  if (typed) next.add(taskId);
  else next.delete(taskId);
  return next;
}

/**
 * Drop typed marks of ids that left the selection.
 *
 * @param prev - The current typed ids.
 * @param taskIds - The ids that left.
 * @returns The same set when none were typed, else a new one.
 */
export function withoutTypedPlacement(
  prev: ReadonlySet<string>,
  taskIds: readonly string[],
): ReadonlySet<string> {
  if (!taskIds.some((id) => prev.has(id))) return prev;
  const next = new Set(prev);
  for (const id of taskIds) next.delete(id);
  return next;
}

/**
 * The wizard's initial placement parameters from a repeating board's FROZEN
 * hand-added goals (`manualTaskTargets`): each entry becomes a typed
 * `targetOverride` / `targetKind` / `titleOverride`, so editing the board and
 * saving writes the same goals back instead of wiping them.
 *
 * @param targets - The record's `manualTaskTargets` (absent = none).
 * @returns The parameters keyed by task id; every key is typed.
 */
export function placementParamsFromManualTargets(
  targets: Record<string, ManualTaskTarget> | undefined,
): Record<string, PlacementParams> {
  const out: Record<string, PlacementParams> = {};
  for (const [id, t] of Object.entries(targets ?? {})) {
    out[id] = {
      targetOverride: t.target,
      targetKind: t.kind,
      ...(t.title !== undefined ? { titleOverride: t.title } : {}),
    };
  }
  return out;
}

/**
 * The freeze of the wizard's hand-added members for a repeating record: only
 * a TYPED goal becomes a `manualTaskTargets` entry (`target` ← `targetOverride`,
 * `kind` ← `targetKind` else discrete, `title` ← `titleOverride`).
 *
 * @param manualTaskIds - The hand-added member ids.
 * @param params - The wizard's placement parameters.
 * @param typedIds - The ids whose entry was typed.
 * @returns The map to persist (empty when nothing was typed).
 */
export function freezeTypedManualTargets(
  manualTaskIds: readonly string[],
  params: ReadonlyMap<string, PlacementParams>,
  typedIds: ReadonlySet<string>,
): Record<string, ManualTaskTarget> {
  const out: Record<string, ManualTaskTarget> = {};
  for (const id of manualTaskIds) {
    const p = params.get(id);
    if (p?.targetOverride == null || !typedIds.has(id)) continue;
    out[id] = {
      target: p.targetOverride,
      kind: p.targetKind ?? 'discrete',
      ...(p.titleOverride !== undefined ? { title: p.titleOverride } : {}),
    };
  }
  return out;
}

/** The wizard's initial placement parameters and which of them were typed. */
export interface WizardPlacementParamsSeed {
  params: Record<string, PlacementParams>;
  typedIds: readonly string[];
}

/**
 * The wizard's initial placement parameters: the draft blob's (with its typed
 * marks) when resuming a draft, else a repeating record's FROZEN goals (every
 * one typed, so editing and saving writes them back), else none.
 *
 * @param draftMix - The decoded draft blob's parameters, or null (no blob).
 * @param manualTaskTargets - The editing record's `manualTaskTargets`.
 * @param manualTaskIds - The record's hand-added ids; a frozen entry for a task
 *   that is no longer hand-added is dropped (iOS `placementParamsFromFrozen`).
 *   Absent = keep every entry.
 * @returns The seed.
 */
export function initialPlacementParamsSeed(
  draftMix: { placementParams: Record<string, PlacementParams>; typedPlacementIds: readonly string[] } | null,
  manualTaskTargets: Record<string, ManualTaskTarget> | undefined,
  manualTaskIds?: readonly string[],
): WizardPlacementParamsSeed {
  if (draftMix) return { params: draftMix.placementParams, typedIds: draftMix.typedPlacementIds };
  const all = placementParamsFromManualTargets(manualTaskTargets);
  const keep = manualTaskIds ? new Set(manualTaskIds) : null;
  const frozen = keep ? Object.fromEntries(Object.entries(all).filter(([id]) => keep.has(id))) : all;
  return { params: frozen, typedIds: Object.keys(frozen) };
}
