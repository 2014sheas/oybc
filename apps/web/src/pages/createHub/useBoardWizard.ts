import { useCallback, useMemo, useState } from 'react';
import {
  CenterSquareType,
  Timeframe,
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
}

export type BoardWizardController = BoardWizardState &
  BoardWizardActions &
  BoardWizardDerived;

export interface UseBoardWizardArgs {
  /** Synced user preferences — used to seed defaults at mount time. */
  preferences: UserPreferences;
  /** Optional starting step (defaults to 1). Useful for tests / drafts. */
  initialStep?: WizardStep;
}

/**
 * useBoardWizard — Owns the full board-creation wizard state.
 *
 * Initializes from `UserPreferences` on mount; any later preference change
 * does NOT stomp in-progress wizard state (mirrors today's
 * `BoardCreatorPanel` snapshot semantics). All step components are fully
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
}: UseBoardWizardArgs): BoardWizardController {
  const [name, setName] = useState('');
  const [size, setSizeRaw] = useState<3 | 4 | 5>(preferences.defaultBoardSize);
  const [timeframe, setTimeframe] = useState<Timeframe>(preferences.defaultTimeframe);
  const [customStartDate, setCustomStartDate] = useState('');
  const [customEndDate, setCustomEndDate] = useState('');
  const [centerType, setCenterTypeRaw] = useState<CenterSquareType>(
    preferences.defaultCenterType,
  );
  const [centerCustomName, setCenterCustomName] = useState(
    preferences.defaultCenterCustomName,
  );
  const [isRandomized, setIsRandomized] = useState(preferences.defaultRandomize);
  const weekStartDay = preferences.weekStartDay;

  const [selectedTaskIds, setSelectedTaskIds] = useState<Set<string>>(new Set());
  const [centerTaskId, setCenterTaskIdRaw] = useState<string | null>(null);

  const [currentStep, setCurrentStep] = useState<WizardStep>(initialStep);

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
  };
}
