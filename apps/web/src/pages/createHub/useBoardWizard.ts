import { useCallback, useMemo, useState } from 'react';
import {
  CenterSquareType,
  Timeframe,
  type Board,
  type BoardTask,
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

  // Step 2 fields
  selectedTaskIds: Set<string>;
  centerTaskId: string | null;

  // Wizard navigation
  currentStep: WizardStep;

  /** Set when the wizard was hydrated from an existing draft board.
   *  Non-null means Save / Activate will update this record rather
   *  than create a new one. */
  draftBoardId: string | null;
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
  /** Optional starting step (defaults to 1). Useful for tests / drafts. */
  initialStep?: WizardStep;
  /** If provided, the wizard hydrates every field from this draft and
   *  subsequent Save / Activate actions update this record rather than
   *  creating a new one. */
  draft?: BoardWizardDraft;
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
  initialStep = 1,
  draft,
}: UseBoardWizardArgs): BoardWizardController {
  const draftBoard = draft?.board;
  const [name, setName] = useState(() => draftBoard?.name ?? '');
  const [size, setSizeRaw] = useState<3 | 4 | 5>(
    () => (draftBoard?.boardSize as 3 | 4 | 5 | undefined) ?? preferences.defaultBoardSize,
  );
  const [timeframe, setTimeframe] = useState<Timeframe>(
    () => draftBoard?.timeframe ?? preferences.defaultTimeframe,
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
  const [centerType, setCenterTypeRaw] = useState<CenterSquareType>(
    () => draftBoard?.centerSquareType ?? preferences.defaultCenterType,
  );
  const [centerCustomName, setCenterCustomName] = useState(
    () => draftBoard?.centerSquareCustomName ?? preferences.defaultCenterCustomName,
  );
  const [isRandomized, setIsRandomized] = useState(
    () => draftBoard?.isRandomized ?? preferences.defaultRandomize,
  );
  const weekStartDay = preferences.weekStartDay;

  const [selectedTaskIds, setSelectedTaskIds] = useState<Set<string>>(
    () => (draft ? new Set(draft.boardTasks.map((bt) => bt.taskId)) : new Set()),
  );
  const [centerTaskId, setCenterTaskIdRaw] = useState<string | null>(
    () => draftBoard?.centerTaskId ?? null,
  );

  const [currentStep, setCurrentStep] = useState<WizardStep>(initialStep);
  const draftBoardId = draftBoard?.id ?? null;

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

  const toggleTaskSelection = useCallback((taskId: string) => {
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
    setSizeRaw(preferences.defaultBoardSize);
    setTimeframe(preferences.defaultTimeframe);
    setCustomStartDate('');
    setCustomEndDate('');
    setCenterTypeRaw(preferences.defaultCenterType);
    setCenterCustomName(preferences.defaultCenterCustomName);
    setIsRandomized(preferences.defaultRandomize);
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
      return `Pick ${short} more task${short === 1 ? '' : 's'}.`;
    }
    if (centerMode && (centerTaskId === null || !selectedTaskIds.has(centerTaskId))) {
      return 'Mark one selected task as the center.';
    }
    return null;
  }, [selectedTaskIds, tasksRequired, centerMode, centerTaskId]);

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
    weekStartDay,
    selectedTaskIds,
    centerTaskId,
    currentStep,
    draftBoardId,

    // Actions
    setName,
    setSize,
    setTimeframe,
    setCustomStartDate,
    setCustomEndDate,
    setCenterType,
    setCenterCustomName,
    setIsRandomized,
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
