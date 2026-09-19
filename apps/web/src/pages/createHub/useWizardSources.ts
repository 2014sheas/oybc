/**
 * useWizardSources.ts — the wizard's SOURCES layer, extracted verbatim from
 * `useBoardWizard.ts` (Board Sources P4 → §Member rules B3; ROADMAP B6
 * posture — the hook file sits on a frozen size cap and the sources block is
 * a clean seam).
 *
 * Owns exactly four pieces of state — the pulled `sources`, the async
 * board-supply cache, the expanded-row set, and the hand-added
 * `manualTaskIds` layer — plus the async board-supply resolution effect and
 * the nine source actions. Everything it needs from the rest of the wizard
 * (the board's fillable cell count, the live pool/task lookups, the current
 * selection, the follow-on-state purge) arrives as arguments, so this hook
 * knows nothing about steps, names, dates, or placement.
 *
 * Behaviour is identical to the pre-extraction code; each action delegates to
 * a pure transition in `wizardSourcesLogic.ts` so it can be unit-tested
 * without a hook renderer (this repo's Vitest harness is `environment:
 * 'node'`).
 *
 * iOS twin: `BoardWizardViewModel+Sources.swift`.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import type { Dispatch, SetStateAction } from 'react';
import type { BoardSource, Pool, Task } from '@oybc/shared';
import { fetchBoardSourceSupply } from '../../db/operations/boardSources';
import {
  buildSupplyInfoMap,
  selectionUnion,
  toggleExcludeInSource,
  type SupplyInfoMap,
} from './wizardSources';
import {
  appendSource,
  boardSupplyEntry,
  droppedSelectionIds,
  removeSourceById,
  toggleIdInSet,
  withResetSourceRange,
  withSourceFilter,
  withSourceRange,
} from './wizardSourcesLogic';

export interface UseWizardSourcesArgs {
  /** Lazy initial `sources` (draft blob > template > empty). */
  initialSources: () => BoardSource[];
  /** Lazy initial hand-added layer. */
  initialManualTaskIds: () => Set<string>;
  /** The board's fillable cell count (`tasksNeededFor(size, centerType)`) —
   *  every range clamp is bounded by it. */
  tasksRequired: number;
  /** Live id→Pool lookup (pool supplies resolve synchronously from it). */
  poolsById: Record<string, Pool>;
  /** False while the pools query is still resolving — an empty `poolsById`
   *  then means "not read yet", never "deleted". */
  poolsLoaded: boolean;
  /** Live id→Task lookup, for pool supply resolution. */
  tasksById: Record<string, Task>;
  /** The wizard's current selection — the diff base for purges. */
  selectedTaskIds: Set<string>;
  /** Purge center/pending/staged state for ids a transition drops. */
  purgeDroppedIds: (droppedIds: string[]) => void;
  /** Mark the user as having touched the selection, so a later-arriving
   *  CoreBoardDefault prefill can never stomp their edits. */
  markUserTouched: () => void;
}

export interface WizardSourcesController {
  sources: BoardSource[];
  /** Escape hatch for the wizard-level actions that also write `sources`
   *  (`toggleTaskSelection`'s exclude-from-every-supplier, the
   *  CoreBoardDefault prefill). */
  setSources: Dispatch<SetStateAction<BoardSource[]>>;
  manualTaskIds: Set<string>;
  setManualTaskIds: Dispatch<SetStateAction<Set<string>>>;
  expandedSourceIds: Set<string>;
  supplyInfoBySourceId: SupplyInfoMap;
  /** Any pulled source whose supply hasn't resolved yet. */
  hasPendingSupply: boolean;
  /** LEGACY mirror (P1 dual-write) — pool-kind ids in row order. */
  pulledPoolIds: string[];
  /** LEGACY mirror (P1 dual-write) — the flat union of every source's excludes. */
  removedTaskIds: Set<string>;
  commitSources: (next: BoardSource[]) => void;
  pullPool: (poolId: string) => void;
  pullBoard: (boardId: string) => void;
  removeSource: (sourceId: string) => void;
  setSourceRange: (sourceId: string, min: number, max: number | null) => void;
  resetSourceRange: (sourceId: string) => void;
  setSourceFilter: (sourceId: string, filter: 'all' | 'todo') => void;
  toggleSourceExclude: (sourceId: string, taskId: string) => void;
  toggleExpandedSource: (sourceId: string) => void;
  /** Reset the whole sources layer (the wizard's `reset()`). */
  resetSources: () => void;
}

/**
 * The wizard's sources layer. See the module docstring for the split.
 *
 * @param args - See {@link UseWizardSourcesArgs}.
 * @returns The sources state, its derived mirrors, and the nine actions.
 */
export function useWizardSources({
  initialSources,
  initialManualTaskIds,
  tasksRequired,
  poolsById,
  poolsLoaded,
  tasksById,
  selectedTaskIds,
  purgeDroppedIds,
  markUserTouched,
}: UseWizardSourcesArgs): WizardSourcesController {
  // Board Sources P4 (docs/BOARD_SOURCES.md) — the wizard is
  // sources-native: `sources` is the state; the legacy trio
  // (`pulledPoolIds`/`removedTaskIds`) is DERIVED below for the P1
  // dual-write.
  const [sources, setSources] = useState<BoardSource[]>(initialSources);
  /** Board-kind supplies, fetched async (pools resolve sync from the live
   *  `poolsById`/`tasksById` props — see `supplyInfoBySourceId` below). */
  const [boardSupplyById, setBoardSupplyById] = useState<SupplyInfoMap>({});
  /** Expanded row state — UI-only, never persisted. */
  const [expandedSourceIds, setExpandedSourceIds] = useState<Set<string>>(new Set());
  /**
   * P3 (Task Pools + Recurring Boards Rework) — the hand-added layer.
   * Hydrated from the draft blob / template; a fresh wizard or a legacy
   * blob-less one-off draft starts from the placed rows (every row defaults
   * to "added by hand" until the user touches a source — an explicit,
   * flagged judgment call: one-off boards have no better provenance to
   * recover).
   */
  const [manualTaskIds, setManualTaskIds] = useState<Set<string>>(initialManualTaskIds);

  // Legacy mirrors — derived from `sources` (the P1 dual-write): pool-kind
  // ids in row order; the flat union of every source's excludes.
  const pulledPoolIds = useMemo(
    () => sources.filter((s) => s.kind === 'pool').map((s) => s.sourceId),
    [sources],
  );
  const removedTaskIds = useMemo(() => {
    const out = new Set<string>();
    for (const source of sources) for (const id of source.excludedTaskIds) out.add(id);
    return out;
  }, [sources]);

  // The combined supply cache: pool entries resolve synchronously from the
  // live `poolsById`/`tasksById` props; board entries come from the async
  // fetch effect below. An unresolvable source keeps an empty supply — it
  // contributes nothing, never blocks.
  const supplyInfoBySourceId = useMemo<SupplyInfoMap>(
    () => buildSupplyInfoMap(sources, poolsById, poolsLoaded, tasksById, boardSupplyById),
    [sources, poolsById, poolsLoaded, tasksById, boardSupplyById],
  );

  /** Any pulled source whose supply hasn't resolved yet. While true the
   *  capacity gate stays quiet — see `step2ValidationMessage`. */
  const hasPendingSupply = useMemo(
    () => Object.values(supplyInfoBySourceId).some((s) => s.isPending === true),
    [supplyInfoBySourceId],
  );

  // Async board-supply resolution (the one structural divergence from the
  // iOS port, whose GRDB reads are synchronous): fetch each board-kind
  // source's supply; re-runs when the pulled board set changes.
  const boardSourceIdsKey = useMemo(
    () => sources.filter((s) => s.kind === 'board').map((s) => s.sourceId).join('|'),
    [sources],
  );
  useEffect(() => {
    const ids = boardSourceIdsKey === '' ? [] : boardSourceIdsKey.split('|');
    if (ids.length === 0) return;
    let cancelled = false;
    void (async () => {
      const next: SupplyInfoMap = {};
      for (const boardId of ids) {
        next[boardId] = boardSupplyEntry(await fetchBoardSourceSupply(boardId));
      }
      if (!cancelled) setBoardSupplyById((prev) => ({ ...prev, ...next }));
    })();
    return () => {
      cancelled = true;
    };
  }, [boardSourceIdsKey]);

  /**
   * Board Sources P4 — apply a sources transition: compute which selected
   * ids the new sources array drops (against the CURRENT supply cache +
   * manual layer), purge their follow-on state, and commit. Action-driven
   * on purpose — the wizard's recompute effect never purges
   * (transient-empty supply hazard during hydration).
   */
  const commitSources = useCallback(
    (next: BoardSource[]) => {
      const nextUnion = selectionUnion(next, supplyInfoBySourceId, manualTaskIds);
      purgeDroppedIds(droppedSelectionIds(selectedTaskIds, nextUnion));
      setSources(next);
    },
    [supplyInfoBySourceId, manualTaskIds, selectedTaskIds, purgeDroppedIds],
  );

  /**
   * Board Sources P4 — pull a pool as a source row (sheet tap when not
   * yet pulled). New rows get the default `[0, all]` range. No-op when
   * already pulled.
   */
  const pullPool = useCallback(
    (poolId: string) => {
      markUserTouched();
      setSources((prev) => appendSource(prev, poolId, 'pool'));
    },
    [markUserTouched],
  );

  /**
   * Board Sources P4 — pull a board as a source row (sheet BOARDS tap).
   * Defaults: `[0, all]`, filter "All squares".
   */
  const pullBoard = useCallback(
    (boardId: string) => {
      markUserTouched();
      setSources((prev) => appendSource(prev, boardId, 'board'));
    },
    [markUserTouched],
  );

  /**
   * Board Sources P4 — remove a source row (the row's ✕, or a sheet
   * un-toggle). Ids the row alone supplied leave the selection; their
   * center/pending/staged state purges.
   */
  const removeSource = useCallback(
    (sourceId: string) => {
      markUserTouched();
      commitSources(removeSourceById(sources, sourceId));
      setExpandedSourceIds((prev) => {
        if (!prev.has(sourceId)) return prev;
        const next = new Set(prev);
        next.delete(sourceId);
        return next;
      });
    },
    [sources, commitSources, markUserTouched],
  );

  /**
   * Board Sources P4 — set one source's range from the slider. `max`
   * latches to "all" as `null`. Min is clamped to
   * `min(available, tasksRequired)` by the caller-side slider bounds AND
   * re-clamped here (defense in depth).
   */
  const setSourceRange = useCallback(
    (sourceId: string, min: number, max: number | null) => {
      setSources((prev) =>
        withSourceRange(prev, supplyInfoBySourceId, sourceId, min, max, tasksRequired),
      );
    },
    [tasksRequired, supplyInfoBySourceId],
  );

  /** Board Sources P4 — "Use all": reset one source's range to `[0, all]`. */
  const resetSourceRange = useCallback((sourceId: string) => {
    setSources((prev) => withResetSourceRange(prev, sourceId));
  }, []);

  /**
   * Board Sources P4 — flip a board source's done-filter. Narrowing to
   * "Not done yet" can drop done squares from the selection → purge via
   * `commitSources`; ranges re-clamp against the new available count.
   */
  const setSourceFilter = useCallback(
    (sourceId: string, filter: 'all' | 'todo') => {
      commitSources(
        withSourceFilter(sources, supplyInfoBySourceId, sourceId, filter, tasksRequired),
      );
    },
    [sources, tasksRequired, supplyInfoBySourceId, commitSources],
  );

  /**
   * Board Sources P4 — toggle one member's exclusion inside ONE source
   * (the expanded panel's ✕ / UNDO). A task excluded from its only
   * supplier (and not hand-added) leaves the selection → purge.
   */
  const toggleSourceExclude = useCallback(
    (sourceId: string, taskId: string) => {
      commitSources(
        toggleExcludeInSource(
          sources,
          supplyInfoBySourceId,
          sourceId,
          taskId,
          tasksRequired,
        ),
      );
    },
    [sources, tasksRequired, supplyInfoBySourceId, commitSources],
  );

  /** Board Sources P4 — expand/collapse a source row (UI-only). */
  const toggleExpandedSource = useCallback((sourceId: string) => {
    setExpandedSourceIds((prev) => toggleIdInSet(prev, sourceId));
  }, []);

  /** Board Sources P4 — reset the sources model alongside the selection. */
  const resetSources = useCallback(() => {
    setSources([]);
    setManualTaskIds(new Set());
    setBoardSupplyById({});
    setExpandedSourceIds(new Set());
  }, []);

  return {
    sources,
    setSources,
    manualTaskIds,
    setManualTaskIds,
    expandedSourceIds,
    supplyInfoBySourceId,
    hasPendingSupply,
    pulledPoolIds,
    removedTaskIds,
    commitSources,
    pullPool,
    pullBoard,
    removeSource,
    setSourceRange,
    resetSourceRange,
    setSourceFilter,
    toggleSourceExclude,
    toggleExpandedSource,
    resetSources,
  };
}
