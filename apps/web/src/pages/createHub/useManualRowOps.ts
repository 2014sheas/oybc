/**
 * useManualRowOps.ts — the wizard's in-place HAND-ADDED row operations:
 * Undo's `restoreToPool` and the counter-row `replaceManualTask` swap. Split
 * out of `useBoardWizard` (file-size cap); it writes only through the
 * setters it is handed. iOS twin: `BoardWizardViewModel.restoreToPool` /
 * `replaceManualTask`.
 */

import { useCallback, type Dispatch, type SetStateAction } from 'react';
import type { PendingTaskPayload } from '../createPage/useCreateFormState';
import type { TaskEditPatch } from '../../db/taskEditPatch';

/** The wizard state setters the row operations write through. */
export interface ManualRowOpsDeps {
  setSelectedTaskIds: Dispatch<SetStateAction<Set<string>>>;
  setPoolOrder: Dispatch<SetStateAction<string[]>>;
  setPendingTasks: Dispatch<SetStateAction<Map<string, PendingTaskPayload>>>;
  setManualTaskIds: Dispatch<SetStateAction<Set<string>>>;
  setStagedEdits: Dispatch<SetStateAction<Map<string, TaskEditPatch>>>;
  setCenterTaskIdRaw: Dispatch<SetStateAction<string | null>>;
  /** Moves a row's dice to the row replacing it. */
  moveManualVary: (fromId: string, toId: string) => void;
}

/**
 * The row operations over the given setters.
 *
 * @param deps - The wizard's state setters.
 * @returns `restoreToPool` and `replaceManualTask` (see `BoardWizardActions`).
 */
export function useManualRowOps(deps: ManualRowOpsDeps): {
  restoreToPool: (taskId: string, index: number, payload: PendingTaskPayload | undefined) => void;
  replaceManualTask: (oldId: string, newId: string, payload: PendingTaskPayload | undefined) => void;
} {
  const {
    setSelectedTaskIds,
    setPoolOrder,
    setPendingTasks,
    setManualTaskIds,
    setStagedEdits,
    setCenterTaskIdRaw,
    moveManualVary,
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

  /** Swap hand-added `oldId` for `newId` at the same position, carrying its dice and center mark. */
  const replaceManualTask = useCallback(
    (oldId: string, newId: string, payload: PendingTaskPayload | undefined) => {
      if (oldId === newId) return;
      const swap = (prev: Set<string>): Set<string> => {
        const next = new Set(prev);
        next.delete(oldId);
        return next.add(newId);
      };
      setSelectedTaskIds(swap);
      setManualTaskIds(swap);
      setPoolOrder((prev) => {
        const i = prev.indexOf(oldId);
        const next = prev.filter((id) => id !== oldId && id !== newId);
        next.splice(i === -1 ? next.length : Math.min(i, next.length), 0, newId);
        return next;
      });
      setPendingTasks((prev) => {
        const next = new Map(prev);
        next.delete(oldId);
        if (payload !== undefined) next.set(newId, payload);
        return next;
      });
      setStagedEdits((prev) => {
        if (!prev.has(oldId)) return prev;
        const next = new Map(prev);
        next.delete(oldId);
        return next;
      });
      setCenterTaskIdRaw((prev) => (prev === oldId ? newId : prev));
      moveManualVary(oldId, newId);
    },
    [setSelectedTaskIds, setManualTaskIds, setPoolOrder, setPendingTasks, setStagedEdits, setCenterTaskIdRaw, moveManualVary],
  );

  return { restoreToPool, replaceManualTask };
}
