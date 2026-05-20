import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDefaultPool } from '../../hooks';
import {
  CenterSquareType,
  Timeframe,
  formatTimeframeLabel,
  getTimeframeBoundaries,
  type Board,
  type BoardTask,
  type RecurringBoardTemplate,
  type UserPreferences,
  type WeekStartDay,
} from '@oybc/shared';

/** A wizard step. 1 = Setup, 2 = Tasks, 3 = Preview & Activate. */
export type WizardStep = 1 | 2 | 3;

/**
 * Returns the number of pool tasks the chosen geometry requires.
 *
 * - Even-sized boards (no center concept): `size²`.
 * - Odd-sized boards with FREE / CUSTOM_FREE center: `size² - 1`
 *   (the center cell is auto-filled, doesn't consume a task).
 * - Odd-sized boards with NONE: `size²` (no special center).
 * - Odd-sized boards with CHOSEN: `size²` (one of the selections IS
 *   the center).
 */
export function tasksNeededFor(size: 3 | 4 | 5, centerType: CenterSquareType): number {
  const isOdd = size % 2 !== 0;
  const hasReservedCenter =
    isOdd &&
    (centerType === CenterSquareType.FREE || centerType === CenterSquareType.CUSTOM_FREE);
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

/** All wizard state held by the controller. */
export interface BoardWizardState {
  // Step 1 fields
  name: string;
  size: 3 | 4 | 5;
  timeframe: Timeframe;
  customStartDate: string; // YYYY-MM-DD
  customEndDate: string; // YYYY-MM-DD
  centerType: CenterSquareType;
  centerCustomName: string;
  isRandomized: boolean;
  weekStartDay: WeekStartDay;

  // Phase 6.2 — recurring template fields. When `isRecurring` is true,
  // the wizard saves a `RecurringBoardTemplate` (and immediately spawns
  // the current window's board); when false, it saves a plain Board as
  // before. The pool is always loose-fit (>= cell count); the spawn
  // shuffles + slices, so any extras become the random subset.
  isRecurring: boolean;

  // Step 2 fields
  selectedTaskIds: Set<string>;
  centerTaskId: string | null;

  // Wizard navigation
  currentStep: WizardStep;

  /** Set when the wizard was hydrated from an existing draft board.
   *  Non-null means Save / Activate will update this record rather
   *  than create a new one. Mutually exclusive with `editingTemplateId`. */
  draftBoardId: string | null;

  /** Set when the wizard was hydrated from an existing recurring
   *  template (Profile → Recurring templates → Edit). Save updates the
   *  template (and does NOT retroactively edit previously-spawned
   *  boards or trigger a fresh spawn). Mutually exclusive with
   *  `draftBoardId`. */
  editingTemplateId: string | null;

  /** Phase 6.1 — true iff the wizard was launched from the recurring
   *  banner (`prefilledRecurringTimeframe != undefined`). Persisted on
   *  the created Board as `isCore: true`, which is the marker the
   *  `findPendingRecurringBoards` detector checks when deciding whether
   *  to keep showing the banner. Manual Create-page opens (no prefill)
   *  leave this false → resulting Board is non-core → banner persists. */
  isCore: boolean;
}

/** Mutators for each piece of state. */
export interface BoardWizardActions {
  setName: (v: string) => void;
  setSize: (s: 3 | 4 | 5) => void;
  setTimeframe: (t: Timeframe) => void;
  setCustomStartDate: (d: string) => void;
  setCustomEndDate: (d: string) => void;
  setCenterType: (t: CenterSquareType) => void;
  setCenterCustomName: (n: string) => void;
  setIsRandomized: (b: boolean) => void;
  setIsRecurring: (b: boolean) => void;
  toggleTaskSelection: (taskId: string) => void;
  setCenterTaskId: (id: string | null) => void;
  goToStep: (step: WizardStep) => void;
  goNext: () => void;
  goBack: () => void;
  reset: () => void;
}

/** Computed flags exposed to step components for validation + display. */
export interface BoardWizardDerived {
  /** Number of pool tasks the chosen geometry requires. */
  tasksRequired: number;
  /** True when CHOSEN center type is selected (drives the star radio). */
  centerMode: boolean;
  /** True when Step 1 is complete enough to advance. */
  isStep1Valid: boolean;
  /** True when Step 2 has enough selections + a center if required. */
  isStep2Valid: boolean;
  /** Optional inline validation message for Step 1. */
  step1ValidationMessage: string | null;
  /** Optional inline validation message for Step 2. */
  step2ValidationMessage: string | null;
  /** True when no meaningful edit has been made — the wizard can be
   *  dismissed without prompting. When a draft is being resumed this
   *  is always `false`: closing a resumed draft is always a decision
   *  worth confirming. */
  isPristine: boolean;
}

export type BoardWizardController = BoardWizardState &
  BoardWizardActions &
  BoardWizardDerived;

/** Payload supplied when resuming an existing draft board. The wizard
 *  hydrates every field from the Board record and rebuilds
 *  `selectedTaskIds` from the BoardTask rows. */
export interface BoardWizardDraft {
  board: Board;
  boardTasks: BoardTask[];
}

export interface UseBoardWizardArgs {
  /** Synced user preferences — used to seed defaults when no draft
   *  is supplied, or as a fallback for fields missing on a draft. */
  preferences: UserPreferences;
  /** Authenticated user id. Used by the Phase 6.X default-pool prefill
   *  path: when the wizard is launched from the recurring banner and a
   *  `DefaultPool` exists for `(userId, timeframe)`, `selectedTaskIds`
   *  is hydrated from `pool.taskIds`. Optional so the wizard still
   *  compiles for tests / playgrounds that don't have an auth context. */
  userId?: string;
  /** Optional starting step (defaults to 1). Useful for tests / drafts. */
  initialStep?: WizardStep;
  /** If provided, the wizard hydrates every field from this draft and
   *  subsequent Save / Activate actions update this record rather than
   *  creating a new one. */
  draft?: BoardWizardDraft;
  /** When set, the wizard is opened from the Boards-tab Recurring
   *  Boards banner. The timeframe is seeded from this value (overriding
   *  `preferences.defaultTimeframe`) and a sensible default name is
   *  precomputed via `formatTimeframeLabel`. The setup step locks the
   *  timeframe field so the user can't accidentally pick a different
   *  one — they can edit name/size/center as usual.
   *
   *  Banner deep-links also turn ON `isRecurring` (since the user is
   *  explicitly creating a recurring instance) so the persist path
   *  saves a template + spawns the current window.
   *
   *  Mutually exclusive with `draft` and `editingTemplate` (drafts and
   *  template-edits already lock semantics by hydrating the full
   *  record). When more than one is supplied, the priority is:
   *  draft > editingTemplate > prefilledRecurringTimeframe. */
  prefilledRecurringTimeframe?: Timeframe;
  /** When set, the wizard is opened in template-edit mode (Profile →
   *  Recurring templates → Edit). All fields hydrate from the template,
   *  `isRecurring` is forced ON, and Save updates the template via
   *  `updateRecurringBoardTemplate` rather than spawning a fresh
   *  template + board. Mutually exclusive with `draft`. */
  editingTemplate?: RecurringBoardTemplate;
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
  editingTemplate,
}: UseBoardWizardArgs): BoardWizardController {
  const draftBoard = draft?.board;

  // Hydration priority: draft > editingTemplate > prefilledRecurringTimeframe.
  // When a draft is being resumed we ignore the other two — drafts already
  // hydrate the full record, so honoring extra prefills on top would
  // confuse the user about which board they're editing. Editing a
  // template wins over a banner-deep-link prefill since the template is
  // a more-specific source.
  const effectiveTemplate = !draftBoard ? editingTemplate ?? undefined : undefined;
  const effectivePrefill =
    !draftBoard &&
    !effectiveTemplate &&
    prefilledRecurringTimeframe !== undefined &&
    prefilledRecurringTimeframe !== Timeframe.CUSTOM
      ? prefilledRecurringTimeframe
      : null;

  // Banner deep-link AND template-edit both imply isRecurring=true.
  const initialIsRecurring = effectiveTemplate !== undefined || effectivePrefill !== null;

  const [name, setName] = useState(() => {
    if (draftBoard) return draftBoard.name;
    if (effectiveTemplate) return effectiveTemplate.name;
    if (effectivePrefill !== null) {
      // Seed with a human-readable label like "Today" / "Week of May 4 – 10,
      // 2026" / "May 2026" / "2026". User can edit before saving.
      const { startDate } = getTimeframeBoundaries(
        effectivePrefill,
        new Date(),
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
  const [timeframe, setTimeframeRaw] = useState<Timeframe>(
    () =>
      draftBoard?.timeframe ??
      effectiveTemplate?.timeframe ??
      effectivePrefill ??
      preferences.defaultTimeframe,
  );
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
    // FREE/CUSTOM_FREE that leaks in from prefs or a malformed draft.
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
  const [centerCustomName, setCenterCustomName] = useState(
    () =>
      draftBoard?.centerSquareCustomName ??
      effectiveTemplate?.centerSquareCustomName ??
      preferences.defaultCenterCustomName,
  );
  const [isRandomized, setIsRandomized] = useState(
    () =>
      draftBoard?.isRandomized ??
      effectiveTemplate?.isRandomized ??
      preferences.defaultRandomize,
  );
  const [isRecurring, setIsRecurringRaw] = useState<boolean>(initialIsRecurring);
  const weekStartDay = preferences.weekStartDay;

  const [selectedTaskIds, setSelectedTaskIds] = useState<Set<string>>(() => {
    if (draft) return new Set(draft.boardTasks.map((bt) => bt.taskId));
    if (effectiveTemplate) return new Set(effectiveTemplate.seedTaskIds);
    return new Set();
  });

  // Phase 6.X — Default Pool prefill. When the wizard is banner-launched
  // (`effectivePrefill` set) AND no draft/template hydrated the
  // selection, look up the user's DefaultPool for that timeframe and
  // seed `selectedTaskIds` from `pool.taskIds`. One-shot via a ref flag
  // so user edits after prefill aren't stomped on later renders — and
  // so a pool that arrives later via sync can't replace selections the
  // user already made.
  //
  // `useDefaultPool` returns a tri-state: `undefined` while loading,
  // `null` when there is no pool for this timeframe, a `DefaultPool`
  // when one exists. Both `null` and a pool object resolve the one-shot
  // decision; only `undefined` should keep the effect waiting.
  const defaultPool = useDefaultPool(
    userId,
    effectivePrefill ?? undefined,
  );
  const poolPrefillAppliedRef = useRef(false);
  useEffect(() => {
    if (poolPrefillAppliedRef.current) return;
    if (draft || effectiveTemplate || effectivePrefill === null) return;
    if (defaultPool === undefined) return; // still loading
    poolPrefillAppliedRef.current = true;
    if (defaultPool !== null && defaultPool.taskIds.length > 0) {
      setSelectedTaskIds(new Set(defaultPool.taskIds));
    }
  }, [defaultPool, draft, effectiveTemplate, effectivePrefill]);
  const [centerTaskId, setCenterTaskIdRaw] = useState<string | null>(
    () => draftBoard?.centerTaskId ?? null,
  );

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
    setSizeRaw(s);
    const newIsOdd = s % 2 !== 0;
    if (!newIsOdd) {
      setCenterTypeRaw(CenterSquareType.NONE);
      setCenterTaskIdRaw(null);
    } else {
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
      if (isRecurring && t === Timeframe.CUSTOM) return;
      setTimeframeRaw(t);
    },
    [isRecurring],
  );

  // Toggling Recurring=ON when timeframe is CUSTOM auto-coerces to
  // DAILY (recurring requires one of the four computed-window
  // timeframes). Surfaced via a one-line hint in the form. Toggling OFF
  // doesn't touch any other state — the user keeps their pool, name,
  // size, etc., and Save reverts to the one-off persist path.
  const setIsRecurring = useCallback((b: boolean) => {
    setIsRecurringRaw(b);
    if (b) {
      setTimeframeRaw((prev) => (prev === Timeframe.CUSTOM ? Timeframe.DAILY : prev));
      // CHOSEN center is also excluded for recurring templates.
      setCenterTypeRaw((prev) => {
        if (prev === CenterSquareType.CHOSEN) {
          setCenterTaskIdRaw(null);
          return CenterSquareType.FREE;
        }
        return prev;
      });
    }
  }, []);

  const toggleTaskSelection = useCallback((taskId: string) => {
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
    // Clear center mark if the task being deselected was the center.
    setCenterTaskIdRaw((prev) => (prev === taskId ? null : prev));
  }, []);

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
    setTimeframeRaw(preferences.defaultTimeframe);
    setCustomStartDate('');
    setCustomEndDate('');
    setCenterCustomName(preferences.defaultCenterCustomName);
    setIsRandomized(preferences.defaultRandomize);
    setIsRecurringRaw(false);
    setSelectedTaskIds(new Set());
    setCenterTaskIdRaw(null);
    setCurrentStep(1);
  }, [preferences]);

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

  // Pool-size enforcement is loose-fit on both branches:
  //   - One-off (isRecurring=false): `selectedCount >= tasksRequired`.
  //     Extras are silently dropped by `buildWizardPlacement`.
  //   - Recurring (isRecurring=true): `selectedCount >= tasksRequired`.
  //     The spawn shuffles + slices, so extras become the random subset.
  // The earlier strict-fit "Use every task" branch was dropped during
  // the Phase 6.2 UX rework — it was a special case of loose-fit where
  // the user picked exactly N.
  const isStep2Valid = useMemo(() => {
    if (selectedTaskIds.size < tasksRequired) return false;
    if (centerMode) {
      if (centerTaskId === null) return false;
      if (!selectedTaskIds.has(centerTaskId)) return false;
    }
    return true;
  }, [selectedTaskIds, tasksRequired, centerMode, centerTaskId]);

  const step2ValidationMessage = useMemo<string | null>(() => {
    const short = tasksRequired - selectedTaskIds.size;
    if (short > 0) {
      const noun = `task${short === 1 ? '' : 's'}`;
      if (isRecurring) return `Pick ${short} more ${noun} (${tasksRequired} minimum).`;
      return `Pick ${short} more ${noun}.`;
    }
    if (centerMode && (centerTaskId === null || !selectedTaskIds.has(centerTaskId))) {
      return 'Mark one selected task as the center.';
    }
    return null;
  }, [selectedTaskIds, tasksRequired, centerMode, centerTaskId, isRecurring]);

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
    centerCustomName,
    isRandomized,
    isRecurring,
    weekStartDay,
    selectedTaskIds,
    centerTaskId,
    currentStep,
    draftBoardId,
    editingTemplateId,
    isCore,

    // Actions
    setName,
    setSize,
    setTimeframe,
    setCustomStartDate,
    setCustomEndDate,
    setCenterType,
    setCenterCustomName,
    setIsRandomized,
    setIsRecurring,
    toggleTaskSelection,
    setCenterTaskId,
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
  };
}
