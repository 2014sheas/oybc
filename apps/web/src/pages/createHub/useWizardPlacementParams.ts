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
import {
  type WizardPlacementParamsSeed,
  withPlacementParamsFor,
  withTypedPlacementFor,
  withoutPlacementParams,
  withoutTypedPlacement,
} from './wizardPlacementParamsLogic';

/** The parameters layer's state and actions. */
export interface WizardPlacementParamsController {
  placementParams: Map<string, PlacementParams>;
  /**
   * The ids whose entry the person TYPED (a hand-typed goal). Only these are
   * frozen into a repeating board's `manualTaskTargets`; an automatic window
   * default stays derived.
   */
  placementTyped: ReadonlySet<string>;
  /** Set (or, with null, clear) one cell's parameters; `typed` marks a hand-typed goal. */
  setPlacementParams: (taskId: string, params: PlacementParams | null, typed?: boolean) => void;
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
 * @param initial - Lazy initial state (draft blob > repeating record's frozen goals > empty).
 * @param tasksById - The wizard's task lookup, for counter roots.
 * @returns The state and its actions.
 */
export function useWizardPlacementParams(
  initial: () => WizardPlacementParamsSeed,
  tasksById: Record<string, Task>,
): WizardPlacementParamsController {
  const [seed] = useState(initial);
  const [placementParams, setParams] = useState<Map<string, PlacementParams>>(
    () => new Map(Object.entries(seed.params)),
  );
  const [placementTyped, setTyped] = useState<ReadonlySet<string>>(() => new Set(seed.typedIds));

  const setPlacementParams = useCallback(
    (taskId: string, params: PlacementParams | null, typed = false) => {
      setParams((prev) => withPlacementParamsFor(prev, taskId, params) as Map<string, PlacementParams>);
      setTyped((prev) => withTypedPlacementFor(prev, taskId, params !== null && typed));
    },
    [],
  );

  const clearPlacementParams = useCallback(() => {
    setParams((prev) => (prev.size === 0 ? prev : new Map()));
    setTyped((prev) => (prev.size === 0 ? prev : new Set()));
  }, []);

  const prunePlacementParamsFor = useCallback((taskIds: readonly string[]) => {
    setParams((prev) => withoutPlacementParams(prev, taskIds) as Map<string, PlacementParams>);
    setTyped((prev) => withoutTypedPlacement(prev, taskIds));
  }, []);

  const restamp = useCallback(
    (from: PlacementBoard, to: PlacementBoard) => {
      setParams((prev) => {
        const next = restampPlacementParams(prev, (id) => tasksById[id], from, to, placementTyped);
        return next === prev ? prev : new Map(next);
      });
    },
    [tasksById, placementTyped],
  );

  return {
    placementParams,
    placementTyped,
    setPlacementParams,
    clearPlacementParams,
    prunePlacementParamsFor,
    restampPlacementParams: restamp,
  };
}
