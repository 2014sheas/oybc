/**
 * useWizardMemberRules.ts — the wizard's MEMBER-RULES layer
 * (docs/BOARD_SOURCES.md §Member rules, B3).
 *
 * Owns the two pieces of state the rules need that the sources layer
 * doesn't — `manualTaskVary` (dice for hand-added counters, persisted on the
 * draft blob / repeating record) and the live `childrenByCompoundId` map a
 * Split-up expansion reads — and the seven rule actions. The rules
 * themselves live ON the sources (`BoardSource.memberRules`), so every
 * action writes through the sources layer's `setSources` / `commitSources`.
 *
 * Two of the seven change the SUPPLY rather than just a number:
 * `setMemberSplit` (a compound becomes N parts instead of 1 square) and
 * `setPartExcluded` (one of those parts drops out). Both therefore re-run
 * the range clamp and go through `commitSources`, exactly like
 * `setSourceFilter` does — RC14.
 *
 * Action names are the cross-platform contract: iOS mirrors them verbatim
 * (B3 Task 6).
 */

import { useCallback, useMemo, useState } from 'react';
import {
  memberRuleFor,
  type BoardSource,
  type CompoundChild,
  type ExpandedSupply,
  type Task,
  type VaryLevel,
} from '@oybc/shared';
import { overlayCompoundChildrenWithStagedEdits, type TaskEditPatch } from '../../db/taskEditPatch';
import type { PendingTaskPayload } from '../createPage/useCreateFormState';
import {
  algorithmSupplies,
  clampAllSourceRanges,
  type SupplyInfoMap,
} from './wizardSources';
import {
  canSetPartExcluded,
  withManualVary,
  withMemberRuleInSource,
  withPartRuleInSource,
} from './wizardMemberRulesLogic';

/**
 * The live compound-children map the wizard's rules + expansion read:
 * the library's links, plus this session's pending (not-yet-persisted)
 * compounds' `childLinks`, plus the staged-edit overlay. Lifted out of
 * `BoardWizardTasksStep`'s local memo so the sources layer can see the same
 * map the UI does — a pending or inline-edited compound must be splittable
 * too.
 *
 * Declared as its own hook (rather than inside `useWizardMemberRules`)
 * because the SOURCES layer needs it as an input, and hooks can't be read
 * before they run.
 *
 * @param compoundChildrenByCompound - The library's links, pre-grouped.
 * @param pendingTasks - This session's not-yet-persisted tasks.
 * @param stagedEdits - Staged inline task edits.
 * @returns Compound id → its effective children, sorted by `childIndex`.
 */
export function useWizardCompoundChildren(
  compoundChildrenByCompound: Record<string, CompoundChild[]>,
  pendingTasks: Map<string, PendingTaskPayload>,
  stagedEdits: Map<string, TaskEditPatch>,
): Record<string, CompoundChild[]> {
  return useMemo<Record<string, CompoundChild[]>>(() => {
    let merged = compoundChildrenByCompound;
    if (pendingTasks.size > 0) {
      merged = { ...merged };
      for (const payload of pendingTasks.values()) {
        if (payload.childLinks.length === 0) continue;
        // `childLinks` are pre-sorted by `childIndex` when assembled in
        // `useCreateFormState` — used as-is, matching `useTaskLibrary`.
        merged[payload.task.id] = payload.childLinks;
      }
    }
    return overlayCompoundChildrenWithStagedEdits(merged, stagedEdits);
  }, [compoundChildrenByCompound, pendingTasks, stagedEdits]);
}

export interface UseWizardMemberRulesArgs {
  /** Lazy initial `manualTaskVary` (draft blob > repeating record > `{}`). */
  initialManualTaskVary: () => Record<string, VaryLevel>;
  /** The sources layer's current rows. */
  sources: BoardSource[];
  /** The sources layer's raw setter (for edits that can't drop a square). */
  setSources: (updater: (prev: BoardSource[]) => BoardSource[]) => void;
  /** The sources layer's commit (purges follow-on state for dropped ids). */
  commitSources: (next: BoardSource[]) => void;
  supplyInfoBySourceId: SupplyInfoMap;
  /** The board's fillable cell count — the range-clamp bound. */
  tasksRequired: number;
  /** Live id→Task lookup (the expansion reads `type`). */
  tasksById: Record<string, Task>;
  /** The live compound-children map (see {@link useWizardCompoundChildren}). */
  childrenByCompoundId: Record<string, CompoundChild[]>;
}

export interface WizardMemberRulesController {
  /** Dice for hand-added counters, keyed by task id. Level 0 is an absence. */
  manualTaskVary: Record<string, VaryLevel>;
  /** The live compound-children map, exposed so the UI never rebuilds it. */
  childrenByCompoundId: Record<string, CompoundChild[]>;
  /** The Split-up-expanded supplies (`applyMemberRules`), row-ordered. */
  expandedSupplies: ExpandedSupply[];
  /** Set (or clear, with `undefined`) a counting member's explicit target. */
  setMemberTarget: (sourceId: string, taskId: string, target: number | undefined) => void;
  /** Set a counting member's (or a One-square compound's) dice level. */
  setMemberVary: (sourceId: string, taskId: string, level: VaryLevel) => void;
  /** Flip a compound member between One square and Split up. */
  setMemberSplit: (sourceId: string, taskId: string, split: boolean) => void;
  /**
   * Include/exclude one part of a split compound. REFUSES to exclude the
   * last included part (a split member always contributes at least one
   * square) — returns `false` and changes nothing.
   */
  setPartExcluded: (
    sourceId: string,
    taskId: string,
    childId: string,
    excluded: boolean,
  ) => boolean;
  /** Set (or clear) a counting part's explicit target. */
  setPartTarget: (
    sourceId: string,
    taskId: string,
    childId: string,
    target: number | undefined,
  ) => void;
  /** Set a counting part's dice level. */
  setPartVary: (sourceId: string, taskId: string, childId: string, level: VaryLevel) => void;
  /** Set a HAND-ADDED counter's dice level (not a source member). */
  setManualVary: (taskId: string, level: VaryLevel) => void;
  /** Reset the rules layer (the wizard's `reset()`). */
  resetMemberRules: () => void;
}

/**
 * The wizard's member-rules layer. See the module docstring.
 *
 * @param args - See {@link UseWizardMemberRulesArgs}.
 * @returns The rules state, the expanded supplies, and the seven actions.
 */
export function useWizardMemberRules({
  initialManualTaskVary,
  sources,
  setSources,
  commitSources,
  supplyInfoBySourceId,
  tasksRequired,
  tasksById,
  childrenByCompoundId,
}: UseWizardMemberRulesArgs): WizardMemberRulesController {
  const [manualTaskVary, setManualTaskVary] =
    useState<Record<string, VaryLevel>>(initialManualTaskVary);

  const expandedSupplies = useMemo<ExpandedSupply[]>(
    () => algorithmSupplies(sources, supplyInfoBySourceId, childrenByCompoundId, tasksById),
    [sources, supplyInfoBySourceId, childrenByCompoundId, tasksById],
  );

  /**
   * A rule edit that changes the SUPPLY (Split up, part exclusion): re-clamp
   * every range against the new available counts, then commit through the
   * sources layer so ids that left the selection purge their follow-on
   * state — the same path `setSourceFilter` takes (RC14).
   */
  const commitSupplyChange = useCallback(
    (next: BoardSource[]) => {
      commitSources(
        clampAllSourceRanges(
          next,
          supplyInfoBySourceId,
          tasksRequired,
          childrenByCompoundId,
          tasksById,
        ),
      );
    },
    [commitSources, supplyInfoBySourceId, tasksRequired, childrenByCompoundId, tasksById],
  );

  const setMemberTarget = useCallback(
    (sourceId: string, taskId: string, target: number | undefined) => {
      setSources((prev) => withMemberRuleInSource(prev, sourceId, taskId, { target }));
    },
    [setSources],
  );

  const setMemberVary = useCallback(
    (sourceId: string, taskId: string, level: VaryLevel) => {
      setSources((prev) => withMemberRuleInSource(prev, sourceId, taskId, { vary: level }));
    },
    [setSources],
  );

  const setMemberSplit = useCallback(
    (sourceId: string, taskId: string, split: boolean) => {
      commitSupplyChange(withMemberRuleInSource(sources, sourceId, taskId, { split }));
    },
    [sources, commitSupplyChange],
  );

  const setPartExcluded = useCallback(
    (sourceId: string, taskId: string, childId: string, excluded: boolean): boolean => {
      const source = sources.find((s) => s.sourceId === sourceId);
      if (source === undefined) return false;
      const partIds = (childrenByCompoundId[taskId] ?? []).map((c) => c.childTaskId);
      if (!canSetPartExcluded(memberRuleFor(source, taskId), partIds, childId, excluded)) {
        return false;
      }
      commitSupplyChange(withPartRuleInSource(sources, sourceId, taskId, childId, { excluded }));
      return true;
    },
    [sources, childrenByCompoundId, commitSupplyChange],
  );

  const setPartTarget = useCallback(
    (sourceId: string, taskId: string, childId: string, target: number | undefined) => {
      setSources((prev) => withPartRuleInSource(prev, sourceId, taskId, childId, { target }));
    },
    [setSources],
  );

  const setPartVary = useCallback(
    (sourceId: string, taskId: string, childId: string, level: VaryLevel) => {
      setSources((prev) => withPartRuleInSource(prev, sourceId, taskId, childId, { vary: level }));
    },
    [setSources],
  );

  const setManualVary = useCallback((taskId: string, level: VaryLevel) => {
    setManualTaskVary((prev) => withManualVary(prev, taskId, level));
  }, []);

  const resetMemberRules = useCallback(() => {
    setManualTaskVary({});
  }, []);

  return {
    manualTaskVary,
    childrenByCompoundId,
    expandedSupplies,
    setMemberTarget,
    setMemberVary,
    setMemberSplit,
    setPartExcluded,
    setPartTarget,
    setPartVary,
    setManualVary,
    resetMemberRules,
  };
}
