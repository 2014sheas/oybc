/**
 * useManualRowOps.ts — the wizard's in-place HAND-ADDED row operations:
 * Undo's `restoreToPool`. Split out of `useBoardWizard` (file-size cap); it writes only through the
 * setters it is handed. iOS twin: `BoardWizardViewModel.restoreToPool`.
 */

import { useCallback, type Dispatch, type SetStateAction } from 'react';
import type { PendingTaskPayload } from '../createPage/useCreateFormState';

/** The wizard state setters the row operations write through. */
export interface ManualRowOpsDeps {
  setSelectedTaskIds: Dispatch<SetStateAction<Set<string>>>;
  setPoolOrder: Dispatch<SetStateAction<string[]>>;
  setPendingTasks: Dispatch<SetStateAction<Map<string, PendingTaskPayload>>>;
  setManualTaskIds: Dispatch<SetStateAction<Set<string>>>;
}

/**
 * The row operations over the given setters.
 *
 * @param deps - The wizard's state setters.
 * @returns `restoreToPool` (see `BoardWizardActions`).
 */
export function useManualRowOps(deps: ManualRowOpsDeps): {
  restoreToPool: (taskId: string, index: number, payload: PendingTaskPayload | undefined) => void;
} {
  const {
    setSelectedTaskIds,
    setPoolOrder,
    setPendingTasks,
    setManualTaskIds,
  } = deps;

  /**
   * Restore a removed task to the pool at its original index. Deliberately
   * does NOT route through `toggleTaskSelection` (which always appends at
   * the end of `poolOrder`) — Undo must restore the task at the exact index
   * it was removed from. A restored task re-enters as a hand-add (manual
   * wins over any standing source exclude, which persists).
   */
  const restoreToPool = useCallback(
    (taskId: string, index: number, payload: PendingTaskPayload | undefined) => {
      setSelectedTaskIds((prev) => (prev.has(taskId) ? prev : new Set(prev).add(taskId)));
      setPoolOrder((prev) => {
        if (prev.includes(taskId)) return prev;
        const next = [...prev];
        next.splice(Math.min(Math.max(index, 0), next.length), 0, taskId);
        return next;
      });
      if (payload !== undefined) setPendingTasks((prev) => new Map(prev).set(taskId, payload));
      setManualTaskIds((prev) => (prev.has(taskId) ? prev : new Set(prev).add(taskId)));
    },
    [setSelectedTaskIds, setPoolOrder, setPendingTasks, setManualTaskIds],
  );

  return { restoreToPool };
}
