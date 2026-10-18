/**
 * useWizardPlacementParams.ts — the wizard's per-cell PLACEMENT PARAMETERS
 * (TASK_WINDOW_REWORK slice 3b, Gate 1 rulings a + b): a quick-added counter
 * ROOT's window goal and a hand-edited counter goal, keyed by task id. They
 * replace the retired pending linked-copy rows: the root is selected as
 * itself and persist writes the parameters onto its `BoardTask`, where an
 * explicit wizard parameter wins over the planner's for that cell.
 *
 * Persisted on the draft blob like `manualTaskVary` (`recurringDraftMix`).
 * iOS twin: `BoardWizardViewModel.placementParams`.
 */

import { useCallback, useState } from 'react';
import type { PlacementBoard, PlacementParams, Task } from '@oybc/shared';
import { restampPlacementParams } from '../../components/wizard/quickAddCounterPlacement';
import { withPlacementParamsFor, withoutPlacementParams } from './wizardPlacementParamsLogic';

/** The parameters layer's state and actions. */
export interface WizardPlacementParamsController {
  placementParams: Map<string, PlacementParams>;
  /** Set (or, with null, clear) one cell's parameters. */
  setPlacementParams: (taskId: string, params: PlacementParams | null) => void;
  /** Drop every cell's parameters. */
  clearPlacementParams: () => void;
  /** Drop the parameters of ids that left the selection. */
  prunePlacementParamsFor: (taskIds: readonly string[]) => void;
  /** Follow a window change: an override at the old window's default moves to the new one's. */
  restampPlacementParams: (from: PlacementBoard, to: PlacementBoard) => void;
}

/**
 * The wizard's placement-parameter state.
 *
 * @param initial - Lazy initial map (draft blob > empty).
 * @param tasksById - The wizard's task lookup, for counter roots.
 * @returns The state and its actions.
 */
export function useWizardPlacementParams(
  initial: () => Record<string, PlacementParams>,
  tasksById: Record<string, Task>,
): WizardPlacementParamsController {
  const [placementParams, setParams] = useState<Map<string, PlacementParams>>(
    () => new Map(Object.entries(initial())),
  );

  const setPlacementParams = useCallback((taskId: string, params: PlacementParams | null) => {
    setParams((prev) => withPlacementParamsFor(prev, taskId, params) as Map<string, PlacementParams>);
  }, []);

  const clearPlacementParams = useCallback(() => {
    setParams((prev) => (prev.size === 0 ? prev : new Map()));
  }, []);

  const prunePlacementParamsFor = useCallback((taskIds: readonly string[]) => {
    setParams((prev) => withoutPlacementParams(prev, taskIds) as Map<string, PlacementParams>);
  }, []);

  const restamp = useCallback(
    (from: PlacementBoard, to: PlacementBoard) => {
      setParams((prev) => {
        const next = restampPlacementParams(prev, (id) => tasksById[id], from, to);
        return next === prev ? prev : new Map(next);
      });
    },
    [tasksById],
  );

  return {
    placementParams,
    setPlacementParams,
    clearPlacementParams,
    prunePlacementParamsFor,
    restampPlacementParams: restamp,
  };
}
