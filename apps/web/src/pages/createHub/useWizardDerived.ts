/**
 * useWizardDerived.ts — the wizard controller's DERIVED flags, extracted
 * from `useBoardWizard.ts` (ROADMAP B6 posture, alongside
 * `useWizardSources`).
 *
 * `boardWizardTypes.ts` already names this slice — the hook returns
 * `BoardWizardDerived` minus `expandedSupplies` (which the rules layer owns)
 * — so it is the same seam the type surface drew: no state, no actions, just
 * the step gates, their copy, the counter-family map and the honest
 * capacity, computed from state the wizard already holds.
 *
 * Extracted in the §Member rules B3 pass because the member-rules layer
 * needed room under `useBoardWizard.ts`'s frozen size cap. Behaviour is
 * unchanged: every memo below is verbatim, with its inputs arriving as
 * arguments instead of closures.
 */

import { useMemo } from 'react';
import {
  CenterSquareType,
  Timeframe,
  buildCounterFamilyMap,
  type BoardSource,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import type { PendingTaskPayload } from '../createPage/useCreateFormState';
import type { BoardWizardDerived, WizardStep } from './boardWizardTypes';
import { sourceCapacity, type SupplyInfoMap } from './wizardSources';

export interface UseWizardDerivedArgs {
  /** The raw (untrimmed) board name. */
  name: string;
  timeframe: Timeframe;
  customStartDate: string;
  customEndDate: string;
  centerType: CenterSquareType;
  centerTaskId: string | null;
  selectedTaskIds: Set<string>;
  sources: BoardSource[];
  supplyInfoBySourceId: SupplyInfoMap;
  manualTaskIds: Set<string>;
  /** §Member rules (B3, RC7) — for the capacity dry-run's Split-up expansion. */
  childrenByCompoundId: Record<string, CompoundChild[]>;
  tasksById: Record<string, Task>;
  pendingTasks: Map<string, PendingTaskPayload>;
  /** True while any pulled source's supply is still resolving. */
  hasPendingSupply: boolean;
  /**
   * The board's fillable cell count. Computed by the caller (the sources
   * layer needs it as an input, so it can't be derived here first) and
   * passed straight back out as part of `BoardWizardDerived`.
   */
  tasksRequired: number;
  draftBoardId: string | null;
  currentStep: WizardStep;
}

/**
 * The wizard's derived flags. See the module docstring.
 *
 * @param args - See {@link UseWizardDerivedArgs}.
 * @returns The `BoardWizardDerived` slice minus `expandedSupplies`, which
 *   the member-rules layer owns and the controller merges in.
 */
export function useWizardDerived({
  name,
  timeframe,
  customStartDate,
  customEndDate,
  centerType,
  centerTaskId,
  selectedTaskIds,
  sources,
  supplyInfoBySourceId,
  manualTaskIds,
  childrenByCompoundId,
  tasksById,
  pendingTasks,
  hasPendingSupply,
  tasksRequired,
  draftBoardId,
  currentStep,
}: UseWizardDerivedArgs): Omit<BoardWizardDerived, 'expandedSupplies'> {
  const centerMode = centerType === CenterSquareType.CHOSEN;
  const trimmedName = name.trim();

  const isStep1Valid = useMemo(() => {
    if (trimmedName.length === 0) return false;
    if (timeframe === Timeframe.CUSTOM) {
      if (!customStartDate || !customEndDate) return false;
      if (customEndDate < customStartDate) return false;
    }
    return true;
  }, [trimmedName, timeframe, customStartDate, customEndDate]);

  const step1ValidationMessage = useMemo<string | null>(() => {
    if (trimmedName.length === 0) return 'Board name is required.';
    if (timeframe === Timeframe.CUSTOM) {
      if (!customStartDate || !customEndDate) return 'Pick a start and end date.';
      if (customEndDate < customStartDate) {
        return 'End date must be on or after the start date.';
      }
    }
    return null;
  }, [trimmedName, timeframe, customStartDate, customEndDate]);

  // Counter-family exclusivity (2026-09-08) — task id → shared-counter
  // family key, over the live library plus this session's pending tasks.
  // Feeds the capacity dry-run and the placement pick so two goals on one
  // counter never (a) inflate the header or (b) land on one board.
  const counterFamilyByTaskId = useMemo<Record<string, string>>(() => {
    const tasks = Object.values(tasksById);
    for (const payload of pendingTasks.values()) {
      tasks.push(payload.task);
      for (const child of payload.childTasks) tasks.push(child);
    }
    return buildCounterFamilyMap(tasks);
  }, [tasksById, pendingTasks]);

  // Board Sources P4 — the step-2 gate compares CAPACITY against the
  // fillable cell count, mirroring iOS `BoardWizardViewModel.isStep2Valid`.
  // Since the counter-family rework this is the HONEST achievable size: a
  // deterministic dry-run of the actual fill (family rule + cap overlap
  // included, the CHOSEN center pinned), so gate-passed ⇒ the deal fills.
  // §Member rules (B3, RC7) — a Split-up member counts as its parts.
  const capacity = useMemo(
    () =>
      sourceCapacity(
        sources,
        supplyInfoBySourceId,
        manualTaskIds,
        counterFamilyByTaskId,
        centerMode ? (centerTaskId ?? undefined) : undefined,
        childrenByCompoundId,
        tasksById,
      ),
    [
      sources, supplyInfoBySourceId, manualTaskIds, counterFamilyByTaskId,
      centerMode, centerTaskId, childrenByCompoundId, tasksById,
    ],
  );

  const isStep2Valid = useMemo(() => {
    if (capacity < tasksRequired) return false;
    if (centerMode) {
      if (centerTaskId === null) return false;
      if (!selectedTaskIds.has(centerTaskId)) return false;
    }
    return true;
  }, [capacity, selectedTaskIds, tasksRequired, centerMode, centerTaskId]);

  const step2ValidationMessage = useMemo<string | null>(() => {
    // Don't accuse the user of a shortfall we can't actually measure yet
    // (late-mutation audit, shape B): while any pulled source's supply is
    // unresolved, capacity is artificially 0, which lit the red gate and
    // disabled Next until the read landed.
    if (hasPendingSupply) return null;
    const short = tasksRequired - capacity;
    if (short > 0) {
      // Design copy (docs/BOARD_SOURCES.md §Surfaces item 1).
      return `${short} more to fill the board.`;
    }
    if (centerMode && (centerTaskId === null || !selectedTaskIds.has(centerTaskId))) {
      return 'Mark one selected task as the center.';
    }
    return null;
  }, [capacity, selectedTaskIds, tasksRequired, centerMode, centerTaskId, hasPendingSupply]);

  const isPristine = useMemo<boolean>(() => {
    if (draftBoardId !== null) return false;
    if (trimmedName.length > 0) return false;
    if (selectedTaskIds.size > 0) return false;
    if (currentStep > 1) return false;
    return true;
  }, [draftBoardId, trimmedName, selectedTaskIds, currentStep]);

  return {
    tasksRequired,
    centerMode,
    isStep1Valid,
    isStep2Valid,
    step1ValidationMessage,
    step2ValidationMessage,
    isPristine,
    capacity,
    suppliesPending: hasPendingSupply,
    counterFamilyByTaskId,
  };
}
