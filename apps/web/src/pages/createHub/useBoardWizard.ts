import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useCoreBoardDefault } from '../../hooks';
import {
  CenterSquareType,
  Timeframe,
  formatWindowLabel,
  getTimeframeBoundaries,
  sourcesForRecord,
  type BoardSource,
  type BoardWindow,
  type CompoundChild,
  type Pool,
  type Task,
} from '@oybc/shared';
import type { PendingTaskPayload } from '../createPage/useCreateFormState';
import type { TaskEditPatch } from '../../db/taskEditPatch';
import { decodeRecurringDraftMix } from '../../db/recurringDraftMix';
import { excludeFromEverySupplier, selectionUnion } from './wizardSources';
import { canApplyTaskToggle } from './wizardMemberRulesLogic';
import { appendSource } from './wizardSourcesLogic';
import { useWizardSources } from './useWizardSources';
import { useWizardCompoundChildren, useWizardMemberRules } from './useWizardMemberRules';
import { useWizardDerived } from './useWizardDerived';
import { resolveInitialWizardTimeframe } from './wizardTimeframeSeed';

/** Stable empty fallback so a caller that omits `tasksById` doesn't cause
 *  a new object identity (and downstream memo churn) every render. */
const EMPTY_TASKS_BY_ID: Record<string, Task> = {};
/** Stable empty fallback for a caller that omits `pools`. */
const EMPTY_POOLS: Pool[] = [];
/** Stable empty fallback for a caller that omits the compound-children map. */
const EMPTY_COMPOUND_CHILDREN: Record<string, CompoundChild[]> = {};

export type {
  WizardStep,
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
  poolsLoaded = true,
  tasksById = EMPTY_TASKS_BY_ID,
  compoundChildrenByCompound = EMPTY_COMPOUND_CHILDREN,
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
      return formatWindowLabel(effectivePrefill, startDate); // absolute: frozen forever
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

  const tasksRequired = useMemo(
    () => tasksNeededFor(size, centerType),
    [size, centerType],
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

  // P5 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
  // §Surfaces item 6 "Core-board setup") — the CoreBoardDefault prefill's
  // one-shot flag. Declared ahead of `useWizardSources` because its source
  // actions mark it too (a user who pulls a pool before the default
  // resolves must never have their edits stomped by it).
  const coreBoardDefault = useCoreBoardDefault(userId, effectivePrefill ?? undefined);
  const poolPrefillAppliedRef = useRef(false);
  const markUserTouched = useCallback(() => {
    poolPrefillAppliedRef.current = true;
  }, []);

  // §Member rules (B3, RC7) — the live compound-children map (library links +
  // this session's pending compounds + the staged-edit overlay). Both the
  // sources layer (Split-up expansion) and the rules layer (part rows) read
  // it, so it is resolved once, ahead of both.
  const childrenByCompoundId = useWizardCompoundChildren(
    compoundChildrenByCompound,
    pendingTasks,
    stagedEdits,
  );

  // §Member rules (B3, RC4) — the window a one-off prefill pro-rates a
  // board-pulled counting target AGAINST. Only `nominalWindowDays` reads it,
  // and that reads start/end for CUSTOM alone (as the `YYYY-MM-DD` prefix),
  // so the raw custom-date inputs are interchangeable with the resolved ISO
  // strings `resolveWizardDates` would produce — and using them keeps this
  // hook off the persist module's date helper. Web twin of iOS
  // `BoardWizardViewModel.prefillTargetWindow`.
  const prefillTargetWindow = useMemo<BoardWindow>(
    () => ({
      timeframe,
      startDate: customStartDate || null,
      endDate: customEndDate || null,
    }),
    [timeframe, customStartDate, customEndDate],
  );

  // Board Sources P4 — the sources layer (state + async supply resolution +
  // the nine source actions) lives in its own hook; see `useWizardSources`.
  const {
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
  } = useWizardSources({
    initialSources: () => decodedRecurringDraftMix?.sources ?? templateHydration?.sources ?? [],
    initialManualTaskIds: () => {
      if (decodedRecurringDraftMix) return new Set(decodedRecurringDraftMix.manualTaskIds);
      if (templateHydration) return new Set(templateHydration.manualTaskIds);
      if (draft) return new Set(draft.boardTasks.map((bt) => bt.taskId));
      return new Set();
    },
    tasksRequired,
    poolsById,
    poolsLoaded,
    tasksById,
    childrenByCompoundId,
    // §Member rules (B3, RC4) — only a ONE-OFF board seeds remaining
    // targets; a repeating board auto-targets against each board's own
    // window instead.
    prefillRemainingTargetsOnResolve: !isRecurring,
    targetWindow: prefillTargetWindow,
    selectedTaskIds,
    purgeDroppedIds,
    markUserTouched,
  });

  // §Member rules (B3) — the rules layer: `manualTaskVary`, the Split-up
  // expansion, and the seven rule actions. Rules live ON the sources, so it
  // writes through the sources layer's setters.
  const {
    manualTaskVary,
    expandedSupplies,
    setMemberTarget,
    setMemberVary,
    setMemberSplit,
    setPartExcluded,
    setPartTarget,
    setPartVary,
    setManualVary,
    pruneManualVaryFor,
    resetMemberRules,
  } = useWizardMemberRules({
    initialManualTaskVary: () =>
      decodedRecurringDraftMix?.manualTaskVary ??
      effectiveTemplate?.manualTaskVary ??
      {},
    sources,
    setSources,
    commitSources,
    supplyInfoBySourceId,
    tasksRequired,
    tasksById,
    pendingTasks,
    childrenByCompoundId,
  });

  // Selection recompute — `selectedTaskIds` tracks the sources-union ∪
  // manual whenever supplies/sources/manual change. Deliberately does NOT
  // purge center/pending/staged here (supplies can be transiently empty
  // while live queries load — a purge would fire on hydration); purging
  // happens in the ACTIONS that drop ids, mirroring iOS's action-driven
  // flow. The step gate re-validates the center against the live
  // selection anyway.
  useEffect(() => {
    const union = selectionUnion(
      sources,
      supplyInfoBySourceId,
      manualTaskIds,
      childrenByCompoundId,
      tasksById,
    );
    setSelectedTaskIds((prev) => {
      if (prev.size === union.size && [...prev].every((id) => union.has(id))) return prev;
      return union;
    });
  }, [sources, supplyInfoBySourceId, manualTaskIds, childrenByCompoundId, tasksById]);

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
    //
    // Minted through `appendSource` rather than an inline literal so the
    // creation defaults (`[0, all]` + the kind-scoped `newSourceFilter`,
    // i.e. `'all'` for these pools) have exactly ONE definition — the two
    // mint paths drifting apart is the whole reason this is a shared helper.
    const prefillSources: BoardSource[] = coreBoardDefault.corePoolIds
      .filter((poolId) => {
        const pool = poolsById[poolId];
        return pool !== undefined && !pool.isDeleted;
      })
      .reduce<BoardSource[]>((acc, poolId) => appendSource(acc, poolId, 'pool'), []);
    const prefillManual = coreBoardDefault.coreDefaultTaskIds.filter((taskId) => {
      const task = tasksById[taskId];
      return task !== undefined && !task.isDeleted;
    });
    if (prefillSources.length === 0 && prefillManual.length === 0) return;
    setSources(prefillSources);
    setManualTaskIds(new Set(prefillManual));
    setPoolOrder(prefillManual);
    // `setSources` / `setManualTaskIds` are stable `useState` setters from
    // the sources hook — listed only to satisfy exhaustive-deps.
  }, [
    coreBoardDefault,
    draft,
    effectiveTemplate,
    effectivePrefill,
    poolsById,
    tasksById,
    setSources,
    setManualTaskIds,
  ]);

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
    (taskId: string): boolean => {
      const wasSelected = selectedTaskIds.has(taskId);
      // §Member rules (B3, review Important #2) — a deselect that the
      // expansion would refuse (the last included part of a Split-up
      // compound) must change NOTHING: dropping the id optimistically and
      // letting the selection recompute restore it is a self-reverting
      // control. Checked before any state write, including the prefill flag.
      //
      // Final review I1 — and it REPORTS the refusal (`false`, exactly like
      // `setPartExcluded`) so the caller can skip its "Removed …" toast: an
      // Undo on a toast for a removal that never happened would call
      // `restoreToPool`, which writes the id into `manualTaskIds` and
      // silently re-provenances a source-supplied part as hand-added.
      if (!canApplyTaskToggle(wasSelected, expandedSupplies, childrenByCompoundId, taskId)) {
        return false;
      }
      // Phase 6.X — user has touched the selection, so any DefaultPool
      // that arrives later via `useLiveQuery` MUST NOT overwrite their
      // edits. Marking the ref here closes the race where the user picks
      // tasks while `defaultPool === undefined` (still loading) and the
      // pool resolution would otherwise re-fire the prefill effect.
      poolPrefillAppliedRef.current = true;
      setSelectedTaskIds((prev) => {
        const next = new Set(prev);
        if (next.has(taskId)) {
          next.delete(taskId);
        } else {
          next.add(taskId);
        }
        return next;
      });
      // Web inline-editing port PR-1 — keep pool order in lockstep; a
      // single toggle only ever adds-or-removes exactly `taskId`.
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
            childrenByCompoundId,
            tasksById,
          ),
        );
        setManualTaskIds((prev) => {
          if (!prev.has(taskId)) return prev;
          const next = new Set(prev);
          next.delete(taskId);
          return next;
        });
        // §Member rules (B3) — a task leaving the hand-added layer takes its
        // dice with it, or the stale entry rides into the draft blob / the
        // repeating record and lives there forever.
        pruneManualVaryFor(taskId);
      } else {
        setManualTaskIds((prev) => {
          if (prev.has(taskId)) return prev;
          const next = new Set(prev);
          next.add(taskId);
          return next;
        });
      }
      return true;
    },
    // `setSources` / `setManualTaskIds` are the sources hook's `useState`
    // setters — stable identities, listed only to satisfy exhaustive-deps.
    [
      selectedTaskIds,
      supplyInfoBySourceId,
      size,
      centerType,
      childrenByCompoundId,
      expandedSupplies,
      tasksById,
      pruneManualVaryFor,
      setSources,
      setManualTaskIds,
    ],
  );


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
    [setManualTaskIds],
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
    resetSources();
    // §Member rules (B3) — and the rules layered on top of it.
    resetMemberRules();
  }, [preferences, isRecurring, resetSources, resetMemberRules]);

  // ── Derived flags ─────────────────────────────────────────────────────
  // The whole `BoardWizardDerived` slice (step gates + copy, the
  // counter-family map, the honest capacity) lives in `useWizardDerived`.
  const derived = useWizardDerived({
    name, timeframe, customStartDate, customEndDate, centerType, centerTaskId,
    selectedTaskIds, sources, supplyInfoBySourceId, manualTaskIds,
    childrenByCompoundId, tasksById, pendingTasks, hasPendingSupply,
    tasksRequired, draftBoardId, currentStep,
  });


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
    manualTaskVary,
    childrenByCompoundId,
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
    setMemberTarget,
    setMemberVary,
    setMemberSplit,
    setPartExcluded,
    setPartTarget,
    setPartVary,
    setManualVary,
    addPendingTask,
    stageEdit,
    revertEdit,
    restoreToPool,
    goToStep,
    goNext,
    goBack,
    reset,

    // Derived
    ...derived,
    expandedSupplies,
  };
}
