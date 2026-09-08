import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useCoreBoardDefault } from '../../hooks';
import {
  CenterSquareType,
  Timeframe,
  formatTimeframeLabel,
  getTimeframeBoundaries,
  sourcesForRecord,
  type BoardSource,
  type Pool,
  type Task,
} from '@oybc/shared';
import type { PendingTaskPayload } from '../createPage/useCreateFormState';
import type { TaskEditPatch } from '../../db/taskEditPatch';
import { decodeRecurringDraftMix } from '../../db/recurringDraftMix';
import { fetchBoardSourceSupply } from '../../db/operations/boardSources';
import {
  availableCountForSource,
  clampAllSourceRanges,
  clampSourceRange,
  excludeFromEverySupplier,
  poolSupplyEntry,
  selectionUnion,
  sourceCapacity,
  toggleExcludeInSource,
  type SupplyInfoMap,
} from './wizardSources';
import { resolveInitialWizardTimeframe } from './wizardTimeframeSeed';

/** Stable empty fallback so a caller that omits `tasksById` doesn't cause
 *  a new object identity (and downstream memo churn) every render. */
const EMPTY_TASKS_BY_ID: Record<string, Task> = {};
/** Stable empty fallback for a caller that omits `pools`. */
const EMPTY_POOLS: Pool[] = [];

export type {
  WizardStep,
  BoardWizardState,
  BoardWizardActions,
  BoardWizardDerived,
  BoardWizardController,
  BoardWizardDraft,
  UseBoardWizardArgs,
} from './boardWizardTypes';
import type {
  WizardStep,
  BoardWizardController,
  UseBoardWizardArgs,
} from './boardWizardTypes';

/**
 * Returns the number of pool tasks the chosen geometry requires.
 *
 * - Even-sized boards (no center concept): `size²`.
 * - Odd-sized boards with FREE center: `size² - 1`
 *   (the center cell is auto-filled, doesn't consume a task).
 * - Odd-sized boards with NONE: `size²` (no special center).
 * - Odd-sized boards with CHOSEN: `size²` (one of the selections IS
 *   the center).
 */
export function tasksNeededFor(size: 3 | 4 | 5, centerType: CenterSquareType): number {
  const isOdd = size % 2 !== 0;
  const hasReservedCenter = isOdd && centerType === CenterSquareType.FREE;
  return size * size - (hasReservedCenter ? 1 : 0);
}


/**
 * Returns a `centerType` that is internally consistent with `size`.
 *
 * Even boards have no center concept; the form hides the center
 * selector for them, so any non-NONE leakage (from prefs, a malformed
 * draft, or a stale reset) would be unfixable from the UI. Coerce to
 * NONE in those cases.
 *
 * Used in three places that all need to converge on the same rule:
 * the initial-state factory, `setSize`, and `reset`.
 */
function coerceCenterType(
  size: 3 | 4 | 5,
  desired: CenterSquareType,
): CenterSquareType {
  const isOdd = size % 2 !== 0;
  if (!isOdd) return CenterSquareType.NONE;
  // Odd boards: NONE is allowed but we usually want a visible default
  // when prefs don't pick one. Honor whatever the caller asked for.
  return desired;
}


/**
 * useBoardWizard — Owns the full board-creation wizard state.
 *
 * Initializes from `UserPreferences` on mount; any later preference change
 * does NOT stomp in-progress wizard state (the wizard takes a snapshot
 * of defaults at construction). All step components are fully
 * controlled — they read from this controller's state and call the
 * exposed setters / nav actions.
 *
 * Validation is exposed as derived booleans (`isStep1Valid`, `isStep2Valid`)
 * so each step can disable its own Next button without re-implementing the
 * count-needed math.
 */
export function useBoardWizard({
  preferences,
  userId,
  initialStep = 1,
  draft,
  prefilledRecurringTimeframe,
  targetWindowDate,
  editingTemplate,
  startRecurring = false,
  pools = EMPTY_POOLS,
  tasksById = EMPTY_TASKS_BY_ID,
}: UseBoardWizardArgs): BoardWizardController {
  const draftBoard = draft?.board;

  // P3 — id→Pool lookup for pull/untoggle/provenance. Rebuilt only when
  // the `pools` array identity changes (the caller's live query).
  const poolsById = useMemo<Record<string, Pool>>(() => {
    const map: Record<string, Pool> = {};
    for (const p of pools) map[p.id] = p;
    return map;
  }, [pools]);

  // Hydration priority: draft > editingTemplate > prefilledRecurringTimeframe
  // > startRecurring. When a draft is being resumed we ignore the other
  // three — drafts already hydrate the full record, so honoring extra
  // prefills on top would confuse the user about which board they're
  // editing. Editing a template wins over a banner-deep-link prefill since
  // the template is a more-specific source; a bare `startRecurring` flag
  // (recurring hub-card tap) is the weakest signal — it only matters for a
  // truly fresh wizard.
  const effectiveTemplate = !draftBoard ? editingTemplate ?? undefined : undefined;
  const effectivePrefill =
    !draftBoard &&
    !effectiveTemplate &&
    prefilledRecurringTimeframe !== undefined &&
    prefilledRecurringTimeframe !== Timeframe.CUSTOM
      ? prefilledRecurringTimeframe
      : null;

  // Board Creation Split (web PR C) — mode is now decided ONCE, from the
  // hydration source or the launch-time `startRecurring` flag, and never
  // changes for the lifetime of this controller (no more Step-1 "Repeats"
  // segmented / `setRepeats` toggle). A wizard *starts* recurring when
  // editing an existing template, OR when launched fresh from the
  // recurring hub card (`startRecurring`). A `prefilledRecurringTimeframe`
  // (banner / core-board browser) creates a one-off *core* board for that
  // window — NOT a repeating board — so it does not flip `isRecurring`
  // (#70) and takes priority over `startRecurring` (mutually exclusive in
  // practice: callers never pass both).
  const isFreshRecurringFromHub =
    draftBoard === undefined &&
    effectiveTemplate === undefined &&
    effectivePrefill === null &&
    startRecurring === true;
  // Board Creation Split (PR B / web PR D) — a resumed draft ALSO forces
  // recurring mode when the draft `Board` itself is marked
  // `isRecurringDraft`. Checked ahead of `isFreshRecurringFromHub` (which
  // already short-circuits to `false` whenever a draft is present anyway)
  // so resuming a recurring draft always reopens the blue wizard, never
  // the red one. Mirrors iOS `BoardWizardViewModel.init`'s
  // `isRecurringAtEntry`.
  const isRecurringDraftResume = draftBoard?.isRecurringDraft === true;
  const initialIsRecurring =
    effectiveTemplate !== undefined || isRecurringDraftResume || isFreshRecurringFromHub;

  const [name, setName] = useState(() => {
    if (draftBoard) return draftBoard.name;
    if (effectiveTemplate) return effectiveTemplate.name;
    if (effectivePrefill !== null) {
      // Seed with a human-readable label like "Today" / "Week of May 4 – 10,
      // 2026" / "May 2026" / "2026". User can edit before saving.
      // `targetWindowDate` (when present) selects a non-today window so
      // the seed name matches the window the user is actually creating.
      const { startDate } = getTimeframeBoundaries(
        effectivePrefill,
        targetWindowDate ?? new Date(),
        preferences.weekStartDay,
      );
      return formatTimeframeLabel(effectivePrefill, startDate);
    }
    return '';
  });
  const [size, setSizeRaw] = useState<3 | 4 | 5>(
    () =>
      (draftBoard?.boardSize as 3 | 4 | 5 | undefined) ??
      (effectiveTemplate?.boardSize as 3 | 4 | 5 | undefined) ??
      preferences.defaultBoardSize,
  );
  // Live mirror of `size` so `setSize` can read the previous value
  // synchronously (matching iOS `updateSize`, which reads the model
  // property) — a render-closure read would go stale if `setSize` were
  // called twice in one render. Synced via effect so external size changes
  // (e.g. `reset`) keep it current.
  const sizeRef = useRef(size);
  useEffect(() => {
    sizeRef.current = size;
  }, [size]);
  const [timeframe, setTimeframeRaw] = useState<Timeframe>(() => {
    const explicitSource =
      draftBoard?.timeframe ??
      effectiveTemplate?.timeframe ??
      effectivePrefill ??
      null;
    return resolveInitialWizardTimeframe(
      explicitSource,
      preferences.defaultTimeframe,
      initialIsRecurring,
      isFreshRecurringFromHub,
    );
  });
  const [customStartDate, setCustomStartDate] = useState(() =>
    draftBoard?.timeframe === Timeframe.CUSTOM && draftBoard.startDate
      ? draftBoard.startDate.slice(0, 10)
      : '',
  );
  const [customEndDate, setCustomEndDate] = useState(() =>
    draftBoard?.timeframe === Timeframe.CUSTOM && draftBoard.endDate
      ? draftBoard.endDate.slice(0, 10)
      : '',
  );
  const [centerType, setCenterTypeRaw] = useState<CenterSquareType>(() =>
    // Even-size boards have no center concept — the BoardSetupForm
    // hides the center selector for them, so the user can't correct a
    // FREE that leaks in from prefs or a malformed draft.
    // Coerce to NONE here so the initial state is internally consistent
    // (matches the same guard in setSize).
    coerceCenterType(
      (draftBoard?.boardSize as 3 | 4 | 5 | undefined) ??
        (effectiveTemplate?.boardSize as 3 | 4 | 5 | undefined) ??
        preferences.defaultBoardSize,
      draftBoard?.centerSquareType ??
        effectiveTemplate?.centerSquareType ??
        preferences.defaultCenterType,
    ),
  );
  // Issue #69 — board placement is always randomized. There's no
  // manual-placement UI, so the per-board "Randomize positions" toggle
  // (and the `defaultRandomize` preference) were dead UX and have been
  // removed. The `isRandomized` field is retained on
  // Board/RecurringBoardTemplate for schema stability and always
  // written `true`; `buildWizardPlacement` / template spawn shuffle
  // unconditionally.
  const isRandomized = true;
  // Board Creation Split (web PR C) — fixed for the lifetime of this
  // controller (recomputed identically every render from stable inputs,
  // so a plain const is equivalent to "set once at init" without needing
  // its own setState). Mirrors iOS's `let isRecurring`.
  const isRecurring = initialIsRecurring;
  const weekStartDay = preferences.weekStartDay;

  // Board Creation Split (web PR D) — a resumed draft's mix decodes
  // synchronously; only the RESOLVED task-id set needs the async effect
  // below. Board Sources P1 (docs/BOARD_SOURCES.md §Data model item 2):
  // ONE-OFF drafts carry the blob too now — legacy blob-less ones keep
  // the boardTasks fallback (null here).
  const hasDraftMixBlob =
    isRecurringDraftResume ||
    (draftBoard !== undefined && draftBoard.recurringDraftMix !== undefined);
  const decodedRecurringDraftMix = useMemo(
    () => (hasDraftMixBlob ? decodeRecurringDraftMix(draftBoard?.recurringDraftMix) : null),
    [hasDraftMixBlob, draftBoard?.recurringDraftMix],
  );

  // Board Sources P4 (docs/BOARD_SOURCES.md) — the wizard is
  // sources-native: `sources` is the state; the legacy trio
  // (`pulledPoolIds`/`removedTaskIds`) is DERIVED below for the P1
  // dual-write. Hydration: draft blob (v2 `sources`) > template
  // (`sourcesForRecord`, with the un-migrated `seedTaskIds`-as-manual
  // fallback — the M2 rule) > empty. Mirrors iOS
  // `BoardWizardViewModel`'s init + `+Sources.swift`.
  const templateHydration = useMemo(() => {
    const t = effectiveTemplate;
    if (!t) return null;
    const isUnmigrated =
      t.sources === undefined &&
      t.poolIds === undefined &&
      t.manualTaskIds === undefined &&
      t.removedTaskIds === undefined;
    return isUnmigrated
      ? { sources: [] as BoardSource[], manualTaskIds: t.seedTaskIds }
      : { sources: sourcesForRecord(t), manualTaskIds: t.manualTaskIds ?? [] };
  }, [effectiveTemplate]);

  const [sources, setSources] = useState<BoardSource[]>(
    () => decodedRecurringDraftMix?.sources ?? templateHydration?.sources ?? [],
  );
  /** Board-kind supplies, fetched async (pools resolve sync from the live
   *  `poolsById`/`tasksById` props — see `supplyInfoBySourceId` below). */
  const [boardSupplyById, setBoardSupplyById] = useState<SupplyInfoMap>({});
  /** Expanded row state — UI-only, never persisted. */
  const [expandedSourceIds, setExpandedSourceIds] = useState<Set<string>>(new Set());

  const [selectedTaskIds, setSelectedTaskIds] = useState<Set<string>>(() => {
    // Synchronous seed; the recompute effect below replaces this with the
    // sources-union as soon as supplies resolve. A LEGACY blob-less
    // one-off draft keeps its placed rows (all hand-added).
    if (decodedRecurringDraftMix) return new Set(decodedRecurringDraftMix.manualTaskIds);
    if (templateHydration) return new Set(templateHydration.manualTaskIds);
    if (draft) return new Set(draft.boardTasks.map((bt) => bt.taskId));
    return new Set();
  });
  // Board Sources P4 — `poolOrder` now orders HAND-ADDED rows only
  // (source members render inside their row's expanded panel).
  const [poolOrder, setPoolOrder] = useState<string[]>(() => {
    if (decodedRecurringDraftMix) return [...decodedRecurringDraftMix.manualTaskIds];
    if (templateHydration) return [...templateHydration.manualTaskIds];
    if (draft) {
      return [
        ...new Set(
          [...draft.boardTasks]
            .sort((a, b) => a.row - b.row || a.col - b.col)
            .map((bt) => bt.taskId),
        ),
      ];
    }
    return [];
  });

  /**
   * P3 (Task Pools + Recurring Boards Rework) — "PULL IN A POOL" state.
   *
   * Editing an existing recurring template — or resuming a recurring
   * draft (Board Creation Split, web PR D) — hydrates directly from the
   * template's / decoded draft mix's own fields (already resolved,
   * synchronous — unlike `selectedTaskIds`'s async resolution above,
   * these three fields need no pool/task lookup to read). A fresh wizard
   * / one-off draft resume carries no persisted pool-mix fields, so
   * `pulledPoolIds`/`removedTaskIds` start empty and `manualTaskIds`
   * starts as the initial `selectedTaskIds` (draft boardTasks, or — via
   * the DefaultPool-prefill effect below — a legacy DefaultPool prefill):
   * every row defaults to "added by hand" until the user touches the new
   * pull-card. This is an explicit, flagged judgment call (P3 spec) —
   * one-off boards have no better provenance to recover. Declared ahead
   * of the prefill effect below since that effect's `setManualTaskIds`
   * needs it in scope.
   */
  const [manualTaskIds, setManualTaskIds] = useState<Set<string>>(() => {
    if (decodedRecurringDraftMix) return new Set(decodedRecurringDraftMix.manualTaskIds);
    if (templateHydration) return new Set(templateHydration.manualTaskIds);
    if (draft) return new Set(draft.boardTasks.map((bt) => bt.taskId));
    return new Set();
  });

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
  const supplyInfoBySourceId = useMemo<SupplyInfoMap>(() => {
    const info: SupplyInfoMap = {};
    for (const source of sources) {
      if (source.kind === 'pool') {
        const pool = poolsById[source.sourceId];
        info[source.sourceId] =
          pool && !pool.isDeleted
            ? poolSupplyEntry(pool, tasksById)
            : { displayName: pool?.name ?? '', rawSupplyTaskIds: [], doneTaskIds: new Set() };
      } else {
        info[source.sourceId] = boardSupplyById[source.sourceId] ?? {
          displayName: '',
          rawSupplyTaskIds: [],
          doneTaskIds: new Set(),
        };
      }
    }
    return info;
  }, [sources, poolsById, tasksById, boardSupplyById]);

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
        const info = await fetchBoardSourceSupply(boardId);
        next[boardId] = info
          ? {
              displayName: info.displayName,
              rawSupplyTaskIds: info.supplyTaskIds,
              doneTaskIds: info.doneTaskIds,
            }
          : { displayName: '', rawSupplyTaskIds: [], doneTaskIds: new Set() };
      }
      if (!cancelled) setBoardSupplyById((prev) => ({ ...prev, ...next }));
    })();
    return () => {
      cancelled = true;
    };
  }, [boardSourceIdsKey]);

  // Selection recompute — `selectedTaskIds` tracks the sources-union ∪
  // manual whenever supplies/sources/manual change. Deliberately does NOT
  // purge center/pending/staged here (supplies can be transiently empty
  // while live queries load — a purge would fire on hydration); purging
  // happens in the ACTIONS that drop ids, mirroring iOS's action-driven
  // flow. The step gate re-validates the center against the live
  // selection anyway.
  useEffect(() => {
    const union = selectionUnion(sources, supplyInfoBySourceId, manualTaskIds);
    setSelectedTaskIds((prev) => {
      if (prev.size === union.size && [...prev].every((id) => union.has(id))) return prev;
      return union;
    });
  }, [sources, supplyInfoBySourceId, manualTaskIds]);

  // P5 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
  // §Surfaces item 6 "Core-board setup") — CoreBoardDefault prefill.
  // Replaces the legacy DefaultPool prefill. When the wizard is
  // banner-launched (`effectivePrefill` set) AND no draft/template
  // hydrated the selection, look up the user's CoreBoardDefault for that
  // timeframe and fold its `corePoolIds` + `coreDefaultTaskIds` into
  // `selectedTaskIds`/`pulledPoolIds` via `applyCoreBoardDefaultPrefill`.
  // One-shot via the SAME ref flag `pullPool`/`untogglePool`/
  // `toggleTaskSelection` already set — a user who starts interacting
  // with pool chips before this resolves is respected; a CoreBoardDefault
  // that arrives later via sync can never stomp their edits.
  //
  // `useCoreBoardDefault` returns a tri-state: `undefined` while loading,
  // `null` when there is no default for this timeframe, a
  // `CoreBoardDefault` when one exists. Both `null` and a resolved row
  // are load-complete signals that resolve the one-shot decision; only
  // `undefined` should keep the effect waiting.
  //
  // Deliberately does NOT touch `manualTaskIds` — every prefilled id here
  // is pool- or default-sourced, never hand-added. This is the actual
  // bug fix vs. the legacy DefaultPool effect, which stuffed the entire
  // prefill into `manualTaskIds` (making every prefilled task read as
  // "added by hand" in the Tasks-step provenance subtitles).
  const coreBoardDefault = useCoreBoardDefault(userId, effectivePrefill ?? undefined);
  const poolPrefillAppliedRef = useRef(false);
  useEffect(() => {
    if (poolPrefillAppliedRef.current) return;
    if (draft || effectiveTemplate || effectivePrefill === null) return;
    if (coreBoardDefault === undefined) return; // still loading
    poolPrefillAppliedRef.current = true;
    if (coreBoardDefault === null) return; // no default configured for this timeframe
    // Board Sources P4 — prefill lands as SOURCES + manual (never a flat
    // resolved selection): each resolvable core pool becomes a default
    // `[0, all]` pool source; the pinned singles become hand-added rows.
    // Dead refs (deleted pools/tasks) are dropped up front — a fresh
    // prefill must not seed unresolvable rows (draft/template hydration
    // deliberately KEEPS refs, since those are the user's own saved
    // state).
    const prefillSources: BoardSource[] = coreBoardDefault.corePoolIds
      .filter((poolId) => {
        const pool = poolsById[poolId];
        return pool !== undefined && !pool.isDeleted;
      })
      .map((poolId) => ({
        sourceId: poolId,
        kind: 'pool',
        min: 0,
        max: null,
        excludedTaskIds: [],
        filter: 'all',
      }));
    const prefillManual = coreBoardDefault.coreDefaultTaskIds.filter((taskId) => {
      const task = tasksById[taskId];
      return task !== undefined && !task.isDeleted;
    });
    if (prefillSources.length === 0 && prefillManual.length === 0) return;
    setSources(prefillSources);
    setManualTaskIds(new Set(prefillManual));
    setPoolOrder(prefillManual);
  }, [coreBoardDefault, draft, effectiveTemplate, effectivePrefill, poolsById, tasksById]);
  const [centerTaskId, setCenterTaskIdRaw] = useState<string | null>(
    () => draftBoard?.centerTaskId ?? null,
  );

  /**
   * Bug #85 — In-memory pending tasks. Keyed by task id. These tasks
   * were created inside the wizard's New Task sheet but have NOT been
   * written to the DB. `persistWizardBoard` drains this map inside the
   * board-save transaction. Abandoning the wizard discards the map with
   * zero cleanup because nothing was ever persisted.
   */
  const [pendingTasks, setPendingTasks] = useState<Map<string, PendingTaskPayload>>(
    () => new Map(),
  );

  /**
   * Inline Task Editing (web PR-2) — staged inline task edits. See
   * `BoardWizardState.stagedEdits`'s doc for the full contract.
   */
  const [stagedEdits, setStagedEdits] = useState<Map<string, TaskEditPatch>>(() => new Map());

  const [currentStep, setCurrentStep] = useState<WizardStep>(initialStep);
  const draftBoardId = draftBoard?.id ?? null;
  const editingTemplateId = effectiveTemplate?.id ?? null;

  // Phase 6.1 — banner-launched ⇒ core. Preserve existing draft's
  // core-ness on resume so a banner-launched draft, once resumed and
  // activated, still marks the board as core. Independent of
  // isRecurring (which the user can toggle freely mid-wizard).
  const isCore = draftBoard?.isCore ?? effectivePrefill !== null;

  // ── Coupled setters ───────────────────────────────────────────────────
  // Changing size or center type can invalidate downstream selections;
  // these setters keep the model consistent so step components don't
  // have to re-implement the same guards.

  const setSize = useCallback((s: 3 | 4 | 5) => {
    const oldIsOdd = sizeRef.current % 2 !== 0;
    sizeRef.current = s; // sync so a back-to-back call sees the live value
    setSizeRaw(s);
    const newIsOdd = s % 2 !== 0;
    if (!newIsOdd) {
      setCenterTypeRaw(CenterSquareType.NONE);
      setCenterTaskIdRaw(null);
    } else if (!oldIsOdd) {
      // Only coerce NONE→FREE when actually crossing even→odd (the even
      // board had forced NONE). Re-selecting the same/another odd size
      // must preserve a deliberate NONE the user picked while already odd.
      setCenterTypeRaw((prev) =>
        prev === CenterSquareType.NONE ? CenterSquareType.FREE : prev,
      );
    }
  }, []);

  const setCenterType = useCallback((t: CenterSquareType) => {
    setCenterTypeRaw(t);
    if (t !== CenterSquareType.CHOSEN) {
      setCenterTaskIdRaw(null);
    }
  }, []);

  // Recurring templates exclude `Timeframe.CUSTOM` (no computed window)
  // and `CenterSquareType.CHOSEN` (MVP scope; the schema rejects both).
  // The setup form hides those options when isRecurring=true, but the
  // setter also rejects them defensively so a stale call site or future
  // refactor can't reintroduce an invalid combination.
  const setTimeframe = useCallback(
    (t: Timeframe) => {
      // Recurring boards exclude CUSTOM and INDEFINITE (no computed window /
      // cadence).
      if (isRecurring && (t === Timeframe.CUSTOM || t === Timeframe.INDEFINITE))
        return;
      setTimeframeRaw(t);
    },
    [isRecurring],
  );

  const toggleTaskSelection = useCallback(
    (taskId: string) => {
      // Phase 6.X — user has touched the selection, so any DefaultPool
      // that arrives later via `useLiveQuery` MUST NOT overwrite their
      // edits. Marking the ref here closes the race where the user picks
      // tasks while `defaultPool === undefined` (still loading) and the
      // pool resolution would otherwise re-fire the prefill effect.
      poolPrefillAppliedRef.current = true;
      const wasSelected = selectedTaskIds.has(taskId);
      setSelectedTaskIds((prev) => {
        const next = new Set(prev);
        if (next.has(taskId)) {
          next.delete(taskId);
        } else {
          next.add(taskId);
        }
        return next;
      });
      // Web inline-editing port PR-1 — keep pool order in lockstep. Cheaper
      // than re-deriving from `selectedTaskIds` via `syncPoolOrder` (which
      // would need the freshly-computed Set in scope); a single toggle only
      // ever adds-or-removes exactly `taskId`.
      setPoolOrder((prev) =>
        wasSelected ? prev.filter((id) => id !== taskId) : prev.includes(taskId) ? prev : [...prev, taskId],
      );
      // Clear center mark if the task being deselected was the center.
      setCenterTaskIdRaw((prev) => (prev === taskId ? null : prev));
      // Bug #85 — When the user deselects a pending (not-yet-persisted)
      // task, remove it from the pending map so it won't be written at
      // board-save time. If it was never pending (library task), this is
      // a no-op because `pendingTasks` won't contain its id.
      setPendingTasks((prev) => {
        if (!prev.has(taskId)) return prev;
        const next = new Map(prev);
        next.delete(taskId);
        return next;
      });
      // Inline Task Editing (web PR-2) — a task leaving the pool always
      // purges its staged edit too (mirrors iOS's exact invariant note on
      // `saveWizardBoard`'s `stagedEdits` parameter).
      setStagedEdits((prev) => {
        if (!prev.has(taskId)) return prev;
        const next = new Map(prev);
        next.delete(taskId);
        return next;
      });

      // Board Sources P4 — the library sheet has no per-source scope, so a
      // deselect excludes the task from EVERY supplying source (the old
      // flat-removal semantics) and drops any hand-add; a select is a
      // manual add — manual WINS over standing excludes (which persist,
      // so removing the hand-add later re-suppresses it).
      if (wasSelected) {
        setSources((prev) =>
          excludeFromEverySupplier(
            prev,
            supplyInfoBySourceId,
            taskId,
            tasksNeededFor(size, centerType),
          ),
        );
        setManualTaskIds((prev) => {
          if (!prev.has(taskId)) return prev;
          const next = new Set(prev);
          next.delete(taskId);
          return next;
        });
      } else {
        setManualTaskIds((prev) => {
          if (prev.has(taskId)) return prev;
          const next = new Set(prev);
          next.add(taskId);
          return next;
        });
      }
    },
    [selectedTaskIds, supplyInfoBySourceId, size, centerType],
  );

  /**
   * Board Sources P4 — purge follow-on state for ids that LEFT the
   * selection via a source action (remove/exclude/filter). Center,
   * pending payloads, and staged edits all drop; `poolOrder` only tracks
   * hand-added rows, which source actions never remove.
   */
  const purgeDroppedIds = useCallback((droppedIds: string[]) => {
    if (droppedIds.length === 0) return;
    const dropped = new Set(droppedIds);
    setCenterTaskIdRaw((prev) => (prev !== null && dropped.has(prev) ? null : prev));
    setPendingTasks((prev) => {
      let changed = false;
      const next = new Map(prev);
      for (const id of droppedIds) {
        if (next.has(id)) {
          next.delete(id);
          changed = true;
        }
      }
      return changed ? next : prev;
    });
    setStagedEdits((prev) => {
      let changed = false;
      const next = new Map(prev);
      for (const id of droppedIds) {
        if (next.has(id)) {
          next.delete(id);
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  }, []);

  /**
   * Board Sources P4 — apply a sources transition: compute which selected
   * ids the new sources array drops (against the CURRENT supply cache +
   * manual layer), purge their follow-on state, and commit. Action-driven
   * on purpose — the recompute effect above never purges (transient-empty
   * supply hazard during hydration).
   */
  const commitSources = useCallback(
    (next: BoardSource[]) => {
      const nextUnion = selectionUnion(next, supplyInfoBySourceId, manualTaskIds);
      purgeDroppedIds([...selectedTaskIds].filter((id) => !nextUnion.has(id)));
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
      poolPrefillAppliedRef.current = true;
      setSources((prev) =>
        prev.some((source) => source.sourceId === poolId)
          ? prev
          : [
              ...prev,
              {
                sourceId: poolId,
                kind: 'pool',
                min: 0,
                max: null,
                excludedTaskIds: [],
                filter: 'all',
              },
            ],
      );
    },
    [],
  );

  /**
   * Board Sources P4 — pull a board as a source row (sheet BOARDS tap).
   * Defaults: `[0, all]`, filter "All squares".
   */
  const pullBoard = useCallback(
    (boardId: string) => {
      poolPrefillAppliedRef.current = true;
      setSources((prev) =>
        prev.some((source) => source.sourceId === boardId)
          ? prev
          : [
              ...prev,
              {
                sourceId: boardId,
                kind: 'board',
                min: 0,
                max: null,
                excludedTaskIds: [],
                filter: 'all',
              },
            ],
      );
    },
    [],
  );

  /**
   * Board Sources P4 — remove a source row (the row's ✕, or a sheet
   * un-toggle). Ids the row alone supplied leave the selection; their
   * center/pending/staged state purges.
   */
  const removeSource = useCallback(
    (sourceId: string) => {
      poolPrefillAppliedRef.current = true;
      commitSources(sources.filter((source) => source.sourceId !== sourceId));
      setExpandedSourceIds((prev) => {
        if (!prev.has(sourceId)) return prev;
        const next = new Set(prev);
        next.delete(sourceId);
        return next;
      });
    },
    [sources, commitSources],
  );

  /**
   * Board Sources P4 — set one source's range from the slider. `max`
   * latches to "all" as `null`. Min is clamped to
   * `min(available, tasksRequired)` by the caller-side slider bounds AND
   * re-clamped here (defense in depth).
   */
  const setSourceRange = useCallback(
    (sourceId: string, min: number, max: number | null) => {
      const required = tasksNeededFor(size, centerType);
      setSources((prev) =>
        prev.map((source) => {
          if (source.sourceId !== sourceId) return source;
          return clampSourceRange(
            { ...source, min, max },
            availableCountForSource(prev, supplyInfoBySourceId, sourceId),
            required,
          );
        }),
      );
    },
    [size, centerType, supplyInfoBySourceId],
  );

  /** Board Sources P4 — "Use all": reset one source's range to `[0, all]`. */
  const resetSourceRange = useCallback((sourceId: string) => {
    setSources((prev) =>
      prev.map((source) =>
        source.sourceId === sourceId ? { ...source, min: 0, max: null } : source,
      ),
    );
  }, []);

  /**
   * Board Sources P4 — flip a board source's done-filter. Narrowing to
   * "Not done yet" can drop done squares from the selection → purge via
   * `commitSources`; ranges re-clamp against the new available count.
   */
  const setSourceFilter = useCallback(
    (sourceId: string, filter: 'all' | 'todo') => {
      const required = tasksNeededFor(size, centerType);
      const next = sources.map((source) =>
        source.sourceId === sourceId && source.kind === 'board'
          ? { ...source, filter }
          : source,
      );
      commitSources(clampAllSourceRanges(next, supplyInfoBySourceId, required));
    },
    [sources, size, centerType, supplyInfoBySourceId, commitSources],
  );

  /**
   * Board Sources P4 — toggle one member's exclusion inside ONE source
   * (the expanded panel's ✕ / UNDO). A task excluded from its only
   * supplier (and not hand-added) leaves the selection → purge.
   */
  const toggleSourceExclude = useCallback(
    (sourceId: string, taskId: string) => {
      const required = tasksNeededFor(size, centerType);
      commitSources(
        toggleExcludeInSource(sources, supplyInfoBySourceId, sourceId, taskId, required),
      );
    },
    [sources, size, centerType, supplyInfoBySourceId, commitSources],
  );

  /** Board Sources P4 — expand/collapse a source row (UI-only). */
  const toggleExpandedSource = useCallback((sourceId: string) => {
    setExpandedSourceIds((prev) => {
      const next = new Set(prev);
      if (next.has(sourceId)) next.delete(sourceId);
      else next.add(sourceId);
      return next;
    });
  }, []);

  /**
   * Bug #85 — Store a pending task payload in the wizard's in-memory
   * map. Called by the Tasks step immediately after the New Task sheet
   * fires `onTaskCreated` (which calls `toggleTaskSelection` to add
   * the id to the selection set). The caller is responsible for calling
   * `toggleTaskSelection` first so the id is always in `selectedTaskIds`
   * before this fires.
   */
  const addPendingTask = useCallback((payload: PendingTaskPayload) => {
    setPendingTasks((prev) => {
      const next = new Map(prev);
      next.set(payload.task.id, payload);
      return next;
    });
  }, []);

  /**
   * Inline Task Editing (web PR-2) — stage an inline edit. See
   * `BoardWizardActions.stageEdit`.
   */
  const stageEdit = useCallback((taskId: string, patch: TaskEditPatch): TaskEditPatch | undefined => {
    let previous: TaskEditPatch | undefined;
    setStagedEdits((prev) => {
      previous = prev.get(taskId);
      const next = new Map(prev);
      next.set(taskId, patch);
      return next;
    });
    return previous;
  }, []);

  /**
   * Inline Task Editing (web PR-2) — undo a staged edit. See
   * `BoardWizardActions.revertEdit`.
   */
  const revertEdit = useCallback((taskId: string, previous: TaskEditPatch | undefined) => {
    setStagedEdits((prev) => {
      const next = new Map(prev);
      if (previous === undefined) {
        next.delete(taskId);
      } else {
        next.set(taskId, previous);
      }
      return next;
    });
  }, []);

  /**
   * Inline Task Editing (web PR-2) — restore a removed task to the pool at
   * its original index. See `BoardWizardActions.restoreToPool`.
   *
   * Deliberately does NOT route through `toggleTaskSelection` (which always
   * appends at the end of `poolOrder`) — Undo must restore the task at the
   * exact index it was removed from, mirroring iOS
   * `BoardWizardViewModel.restoreToPool`.
   */
  const restoreToPool = useCallback(
    (taskId: string, index: number, payload: PendingTaskPayload | undefined) => {
      setSelectedTaskIds((prev) => {
        if (prev.has(taskId)) return prev;
        const next = new Set(prev);
        next.add(taskId);
        return next;
      });
      setPoolOrder((prev) => {
        if (prev.includes(taskId)) return prev;
        const next = [...prev];
        next.splice(Math.min(Math.max(index, 0), next.length), 0, taskId);
        return next;
      });
      if (payload !== undefined) {
        setPendingTasks((prev) => {
          const next = new Map(prev);
          next.set(taskId, payload);
          return next;
        });
      }
      // Board Sources P4 — a restored task re-enters as a hand-add (manual
      // wins over any standing source exclude, which persists).
      setManualTaskIds((prev) => {
        if (prev.has(taskId)) return prev;
        const next = new Set(prev);
        next.add(taskId);
        return next;
      });
    },
    [],
  );

  const setCenterTaskId = useCallback((id: string | null) => {
    setCenterTaskIdRaw(id);
  }, []);

  // ── Step navigation ───────────────────────────────────────────────────

  const goToStep = useCallback((step: WizardStep) => {
    setCurrentStep(step);
  }, []);

  const goNext = useCallback(() => {
    setCurrentStep((s) => (s < 3 ? ((s + 1) as WizardStep) : s));
  }, []);

  const goBack = useCallback(() => {
    setCurrentStep((s) => (s > 1 ? ((s - 1) as WizardStep) : s));
  }, []);

  const reset = useCallback(() => {
    setName('');
    // Re-apply size + centerType through the same coercion the initial
    // factory uses, so reset can never reintroduce an even-board+FREE
    // mismatch. Going via `setSizeRaw` + `coerceCenterType` rather than
    // calling `setSize` so the centerType honours the pref instead of
    // always being normalised to FREE.
    const nextSize = preferences.defaultBoardSize;
    setSizeRaw(nextSize);
    setCenterTypeRaw(coerceCenterType(nextSize, preferences.defaultCenterType));
    // Board Creation Split (web PR C) — `isRecurring` is fixed for this
    // controller's lifetime, so reset() must respect the current mode
    // rather than resolving the one-off `defaultTimeframe` preference
    // unconditionally. Mirrors init's own per-mode default.
    if (isRecurring) {
      setTimeframeRaw(Timeframe.WEEKLY);
    } else {
      // Mirror the init seed's CUSTOM→INDEFINITE default so a reset wizard
      // opens ongoing (End date = None), not on CUSTOM with empty dates.
      setTimeframeRaw(
        preferences.defaultTimeframe === Timeframe.CUSTOM
          ? Timeframe.INDEFINITE
          : preferences.defaultTimeframe,
      );
    }
    setCustomStartDate('');
    setCustomEndDate('');
    setSelectedTaskIds(new Set());
    setPoolOrder([]);
    setCenterTaskIdRaw(null);
    setPendingTasks(new Map());
    setStagedEdits(new Map());
    setCurrentStep(1);
    // Board Sources P4 — reset the sources model alongside the selection.
    setSources([]);
    setManualTaskIds(new Set());
    setBoardSupplyById({});
    setExpandedSourceIds(new Set());
  }, [preferences, isRecurring]);

  // ── Derived flags ─────────────────────────────────────────────────────

  const tasksRequired = useMemo(
    () => tasksNeededFor(size, centerType),
    [size, centerType],
  );
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

  // Board Sources P4 — the step-2 gate compares CAPACITY (sum of every
  // source's effective max + hand-added, deduped — docs/BOARD_SOURCES.md
  // §Selection step 3) against the fillable cell count, mirroring iOS
  // `BoardWizardViewModel.isStep2Valid`. For all-`[0,all]` sources this
  // equals the old flat selection count, so pre-rework behavior is
  // unchanged; a numeric max caps what a source can contribute and the
  // gate respects it.
  const capacity = useMemo(
    () => sourceCapacity(sources, supplyInfoBySourceId, manualTaskIds),
    [sources, supplyInfoBySourceId, manualTaskIds],
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
    const short = tasksRequired - capacity;
    if (short > 0) {
      // Design copy (docs/BOARD_SOURCES.md §Surfaces item 1).
      return `${short} more to fill the board.`;
    }
    if (centerMode && (centerTaskId === null || !selectedTaskIds.has(centerTaskId))) {
      return 'Mark one selected task as the center.';
    }
    return null;
  }, [capacity, selectedTaskIds, tasksRequired, centerMode, centerTaskId]);

  const isPristine = useMemo<boolean>(() => {
    if (draftBoardId !== null) return false;
    if (trimmedName.length > 0) return false;
    if (selectedTaskIds.size > 0) return false;
    if (currentStep > 1) return false;
    return true;
  }, [draftBoardId, trimmedName, selectedTaskIds, currentStep]);

  return {
    // State
    name,
    size,
    timeframe,
    customStartDate,
    customEndDate,
    centerType,
    isRandomized,
    isRecurring,
    weekStartDay,
    selectedTaskIds,
    centerTaskId,
    poolOrder,
    sources,
    manualTaskIds,
    supplyInfoBySourceId,
    expandedSourceIds,
    pulledPoolIds,
    removedTaskIds,
    pendingTasks,
    stagedEdits,
    currentStep,
    draftBoardId,
    editingTemplateId,
    isCore,
    targetWindowDate: targetWindowDate ?? null,

    // Actions
    setName,
    setSize,
    setTimeframe,
    setCustomStartDate,
    setCustomEndDate,
    setCenterType,
    toggleTaskSelection,
    setCenterTaskId,
    pullPool,
    pullBoard,
    removeSource,
    setSourceRange,
    resetSourceRange,
    setSourceFilter,
    toggleSourceExclude,
    toggleExpandedSource,
    addPendingTask,
    stageEdit,
    revertEdit,
    restoreToPool,
    goToStep,
    goNext,
    goBack,
    reset,

    // Derived
    tasksRequired,
    centerMode,
    isStep1Valid,
    isStep2Valid,
    step1ValidationMessage,
    step2ValidationMessage,
    isPristine,
    capacity,
  };
}
