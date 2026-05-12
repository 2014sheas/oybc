import { useCallback, useState } from 'react';
import {
  TaskType,
  OperatorType,
  generateCounterTaskTitle,
  type Task,
  type CreateCompoundChildEntry,
} from '@oybc/shared';
import { createTask, createCompound } from '../../db/operations/tasks';
import { type StepFormState, createEmptyStep } from '../../components/progressStepUtils';
/**
 * Union of TaskType values plus the form-only sentinels `'progress'` and
 * `'composite'`. Both sentinels are submission strategies — neither exists
 * in the runtime TaskType enum after the compound-tasks unification:
 *   - `'progress'` → `createCompound({ operator: 'AND', isOrdered: true, ... })`
 *   - `'composite'` → opens the dedicated `CompositeTaskWizard`
 */
export type TaskTypeOrComposite = TaskType | typeof PROGRESS_TYPE | typeof COMPOSITE_TYPE;
export const COMPOSITE_TYPE = 'composite' as const;
export const PROGRESS_TYPE = 'progress' as const;

// ─── Constants (shared with the Create-tab UIs that consume this hook) ──────

export const TITLE_MAX_LENGTH = 200;
export const DESCRIPTION_MAX_LENGTH = 1000;
export const ACTION_MAX_LENGTH = 50;
export const UNIT_MAX_LENGTH = 50;
export const STEP_TITLE_MAX_LENGTH = 200;

// ─── Error shape ──────────────────────────────────────────────────────────────

/** Phase 6.3 — mode picker for ACHIEVEMENT task creation. The form
 *  tracks which mode is selected so the right picker renders; submit
 *  serializes the choice into a single `referencedBoardId` OR
 *  `referencedTemplateId` field on the new Task. */
export type AchievementMode = 'specificBoard' | 'recurringTemplate';

export interface FormErrors {
  title?: string;
  description?: string;
  action?: string;
  unit?: string;
  maxCount?: string;
  /** Phase 6.3 — surfaces when an Achievement task lacks a picker
   *  selection or fails cycle detection. */
  achievementReference?: string;
  steps?: Record<string, { title?: string; action?: string; unit?: string; maxCount?: string }>;
  general?: string;
}

// ─── Validation ──────────────────────────────────────────────────────────────

/**
 * Pure form-validation function. Returns an error object keyed by
 * field; empty object means "valid". Kept exported so an outside
 * caller (e.g. an integration test, or a future submit confirmation
 * flow) can validate without instantiating the hook.
 *
 * Phase 6.3 — When `type === ACHIEVEMENT`, the validator demands a
 * picker selection that matches the chosen mode. The cycle-detection
 * check happens in `handleSubmit` (it needs DB context the validator
 * can't see).
 */
export function validateForm(
  type: TaskTypeOrComposite,
  title: string,
  description: string,
  action: string,
  unit: string,
  maxCountStr: string,
  steps: StepFormState[],
  achievementMode?: AchievementMode,
  achievementReferenceId?: string | null,
): FormErrors {
  const errors: FormErrors = {};

  const trimmedTitle = title.trim();
  if (type !== TaskType.COUNTING && trimmedTitle.length === 0) {
    errors.title = 'Title is required';
  } else if (trimmedTitle.length > TITLE_MAX_LENGTH) {
    errors.title = `Title must be ${TITLE_MAX_LENGTH} characters or less`;
  }

  if (description.length > DESCRIPTION_MAX_LENGTH) {
    errors.description = `Description must be ${DESCRIPTION_MAX_LENGTH} characters or less`;
  }

  if (type === TaskType.COUNTING) {
    if (action.trim().length === 0) {
      errors.action = 'Action is required';
    } else if (action.trim().length > ACTION_MAX_LENGTH) {
      errors.action = `Action must be ${ACTION_MAX_LENGTH} characters or less`;
    }

    if (unit.trim().length === 0) {
      errors.unit = 'Unit is required';
    } else if (unit.trim().length > UNIT_MAX_LENGTH) {
      errors.unit = `Unit must be ${UNIT_MAX_LENGTH} characters or less`;
    }

    if (maxCountStr.trim().length === 0) {
      errors.maxCount = 'Max count is required';
    } else {
      const parsed = parseInt(maxCountStr, 10);
      if (isNaN(parsed) || parsed <= 0) {
        errors.maxCount = 'Max count must be a positive integer';
      }
    }
  }

  if (type === TaskType.ACHIEVEMENT) {
    // Achievement tasks must reference exactly one target — the form's
    // submit pipeline serializes the mode + reference id into either
    // `referencedBoardId` or `referencedTemplateId` on the new Task.
    if (!achievementMode) {
      errors.achievementReference = 'Pick a mode (specific board or recurring template)';
    } else if (!achievementReferenceId) {
      errors.achievementReference =
        achievementMode === 'specificBoard'
          ? 'Pick a board to watch'
          : 'Pick a recurring template to watch';
    }
  }

  if (type === PROGRESS_TYPE) {
    const stepErrors: FormErrors['steps'] = {};
    let hasStepErrors = false;

    for (const step of steps) {
      const errs: { title?: string; action?: string; unit?: string; maxCount?: string } = {};

      const trimmedStepTitle = step.title.trim();
      if (step.type !== 'counting' && trimmedStepTitle.length === 0) {
        errs.title = 'Step title is required';
      } else if (trimmedStepTitle.length > STEP_TITLE_MAX_LENGTH) {
        errs.title = `Step title must be ${STEP_TITLE_MAX_LENGTH} characters or less`;
      }

      if (step.type === 'counting') {
        if (step.action.trim().length === 0) {
          errs.action = 'Action is required for counting steps';
        } else if (step.action.trim().length > ACTION_MAX_LENGTH) {
          errs.action = `Action must be ${ACTION_MAX_LENGTH} characters or less`;
        }

        if (step.unit.trim().length === 0) {
          errs.unit = 'Unit is required for counting steps';
        } else if (step.unit.trim().length > UNIT_MAX_LENGTH) {
          errs.unit = `Unit must be ${UNIT_MAX_LENGTH} characters or less`;
        }

        if (step.maxCount.trim().length === 0) {
          errs.maxCount = 'Max count is required for counting steps';
        } else {
          const parsed = parseInt(step.maxCount, 10);
          if (isNaN(parsed) || parsed <= 0) {
            errs.maxCount = 'Max count must be a positive number';
          }
        }
      }

      if (Object.keys(errs).length > 0) {
        stepErrors![step.id] = errs;
        hasStepErrors = true;
      }
    }

    if (hasStepErrors) {
      errors.steps = stepErrors;
    }
  }

  return errors;
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export interface UseCreateFormStateArgs {
  userId: string | undefined;
  /** Called when a task was successfully created. Gives the container
   *  a single integration point for "add to pool + flash a toast". */
  onTaskCreated: (task: Task) => void;
}

export interface UseCreateFormState {
  // Form fields
  taskType: TaskTypeOrComposite;
  title: string;
  description: string;
  action: string;
  unit: string;
  maxCountStr: string;
  steps: StepFormState[];
  errors: FormErrors;
  isSubmitting: boolean;

  // Phase 6.3 — Achievement-task fields.
  achievementMode: AchievementMode;
  achievementReferenceId: string | null;
  setAchievementMode: (mode: AchievementMode) => void;
  setAchievementReferenceId: (id: string | null) => void;

  /**
   * The counting Task currently used as a derivation template, or null.
   * When set, the form's `action` and `unit` are pre-filled from this task
   * and the banner shows the source title. Only relevant when taskType ===
   * TaskType.COUNTING.
   */
  deriveFromTask: Task | null;

  // Setters (with inline error-clearing where appropriate)
  setTitle: (v: string) => void;
  setDescription: (v: string) => void;
  setAction: (v: string) => void;
  setUnit: (v: string) => void;
  setMaxCountStr: (v: string) => void;
  handleTypeChange: (v: TaskTypeOrComposite) => void;

  /**
   * Applies a counting task as the derivation template: sets `action` and
   * `unit` from the source task and clears `maxCountStr` so the user must
   * enter a fresh count. Also clears any stale field errors for those fields.
   */
  applyTemplate: (source: Task) => void;

  /**
   * Clears the derivation template and resets `action`, `unit`, and
   * `maxCountStr` back to empty strings so the form is fresh.
   */
  clearTemplate: () => void;

  // Step-array helpers
  updateStep: (stepId: string, field: keyof StepFormState, value: string) => void;
  addStep: () => void;
  removeStep: (stepId: string) => void;

  // Submission
  handleSubmit: (e: React.FormEvent) => Promise<void>;
}

/**
 * Owns the "Create New" tab's form state on the Create page — every
 * input field, its validation errors, and the submit pipeline.
 *
 * Submit is async: on success it trims fields, calls `createTask`
 * with the right shape per task type (NORMAL / COUNTING / PROGRESS),
 * hands the new task to `onTaskCreated`, and resets the form.
 * Errors surface as `errors.general`. Composite creation doesn't
 * flow through this hook — the Composite form is its own component.
 */
export function useCreateFormState({ userId, onTaskCreated }: UseCreateFormStateArgs): UseCreateFormState {
  const [taskType, setTaskType] = useState<TaskTypeOrComposite>(TaskType.NORMAL);
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [action, setAction] = useState('');
  const [unit, setUnit] = useState('');
  const [maxCountStr, setMaxCountStr] = useState('');
  const [steps, setSteps] = useState<StepFormState[]>([createEmptyStep()]);
  const [errors, setErrors] = useState<FormErrors>({});
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [deriveFromTask, setDeriveFromTask] = useState<Task | null>(null);
  // Phase 6.3 — Achievement-task state. `specificBoard` is the default
  // mode because most users will likely watch a single named board (a
  // longer-running monthly/yearly) rather than a template's spawns.
  const [achievementMode, setAchievementMode] = useState<AchievementMode>('specificBoard');
  const [achievementReferenceId, setAchievementReferenceId] = useState<string | null>(null);

  /**
   * Wrap a plain setter so editing a field also clears its own error —
   * matches the pattern the legacy Create tab used inline for every
   * input. Keeps the UX invariant that typing resolves the red state.
   */
  /**
   * Memoised with empty deps so the setter `useCallback`s below can
   * depend on it without being re-created every render. `setErrors`
   * from `useState` is already referentially stable, so this closure
   * is stable too.
   */
  const clearFieldError = useCallback(<K extends keyof FormErrors>(field: K): void => {
    setErrors((prev) => (prev[field] === undefined ? prev : { ...prev, [field]: undefined }));
  }, []);

  const setTitleClearingError = useCallback((v: string) => {
    setTitle(v);
    clearFieldError('title');
  }, [clearFieldError]);
  const setDescriptionClearingError = useCallback((v: string) => {
    setDescription(v);
    clearFieldError('description');
  }, [clearFieldError]);
  const setActionClearingError = useCallback((v: string) => {
    setAction(v);
    clearFieldError('action');
  }, [clearFieldError]);
  const setUnitClearingError = useCallback((v: string) => {
    setUnit(v);
    clearFieldError('unit');
  }, [clearFieldError]);
  const setMaxCountStrClearingError = useCallback((v: string) => {
    setMaxCountStr(v);
    clearFieldError('maxCount');
  }, [clearFieldError]);

  const handleTypeChange = useCallback((newType: TaskTypeOrComposite) => {
    setTaskType(newType);
    // Clear the template AND the fields it populated — otherwise switching
    // away from Counting and back leaves stale `action` / `unit` populated
    // with the picker showing the "Use template" affordance, silently
    // submitting another task's action+unit.
    setDeriveFromTask(null);
    setAction('');
    setUnit('');
    setMaxCountStr('');
    // Phase 6.3 — clear achievement-mode picker so switching to ACHIEVEMENT
    // doesn't surface a stale reference id from a prior selection.
    setAchievementReferenceId(null);
    setErrors((prev) => ({
      ...prev,
      action: undefined,
      unit: undefined,
      maxCount: undefined,
      achievementReference: undefined,
      steps: undefined,
    }));
  }, []);

  const handleAchievementModeChange = useCallback((mode: AchievementMode) => {
    setAchievementMode(mode);
    // Clear the picker selection — switching from `specificBoard` to
    // `recurringTemplate` (or back) shouldn't keep an ineligible id.
    setAchievementReferenceId(null);
    setErrors((prev) =>
      prev.achievementReference === undefined ? prev : { ...prev, achievementReference: undefined },
    );
  }, []);

  const handleAchievementReferenceChange = useCallback((id: string | null) => {
    setAchievementReferenceId(id);
    setErrors((prev) =>
      prev.achievementReference === undefined ? prev : { ...prev, achievementReference: undefined },
    );
  }, []);

  const applyTemplate = useCallback((source: Task) => {
    setDeriveFromTask(source);
    setAction(source.action ?? '');
    setUnit(source.unit ?? '');
    setMaxCountStr('');
    setErrors((prev) => ({ ...prev, action: undefined, unit: undefined, maxCount: undefined }));
  }, []);

  const clearTemplate = useCallback(() => {
    setDeriveFromTask(null);
    setAction('');
    setUnit('');
    setMaxCountStr('');
    setErrors((prev) => ({ ...prev, action: undefined, unit: undefined, maxCount: undefined }));
  }, []);

  const updateStep = useCallback((stepId: string, field: keyof StepFormState, value: string) => {
    setSteps((prev) => prev.map((s) => (s.id === stepId ? { ...s, [field]: value } : s)));
    setErrors((prev) => {
      if (!prev.steps?.[stepId]) return prev;
      const newStepErrors = { ...prev.steps };
      newStepErrors[stepId] = { ...newStepErrors[stepId], [field]: undefined };
      if (Object.values(newStepErrors[stepId]).every((v) => v === undefined)) {
        delete newStepErrors[stepId];
      }
      const hasStepErrors = Object.keys(newStepErrors).length > 0;
      return { ...prev, steps: hasStepErrors ? newStepErrors : undefined };
    });
  }, []);

  const addStep = useCallback(() => {
    setSteps((prev) => [...prev, createEmptyStep()]);
  }, []);

  const removeStep = useCallback((stepId: string) => {
    setSteps((prev) => (prev.length <= 1 ? prev : prev.filter((s) => s.id !== stepId)));
    setErrors((prev) => {
      if (!prev.steps?.[stepId]) return prev;
      const newStepErrors = { ...prev.steps };
      delete newStepErrors[stepId];
      const hasStepErrors = Object.keys(newStepErrors).length > 0;
      return { ...prev, steps: hasStepErrors ? newStepErrors : undefined };
    });
  }, []);

  function resetForm(): void {
    setTaskType(TaskType.NORMAL);
    setTitle('');
    setDescription('');
    setAction('');
    setUnit('');
    setMaxCountStr('');
    setSteps([createEmptyStep()]);
    setErrors({});
    setDeriveFromTask(null);
    setAchievementMode('specificBoard');
    setAchievementReferenceId(null);
  }

  const handleSubmit = useCallback(
    async (e: React.FormEvent): Promise<void> => {
      e.preventDefault();

      if (taskType === COMPOSITE_TYPE || !userId) return;

      const validationErrors = validateForm(
        taskType,
        title,
        description,
        action,
        unit,
        maxCountStr,
        steps,
        achievementMode,
        achievementReferenceId,
      );
      setErrors(validationErrors);
      if (Object.keys(validationErrors).length > 0) return;

      setIsSubmitting(true);
      try {
        let newTask: Task;

        if (taskType === TaskType.NORMAL) {
          newTask = await createTask(userId, {
            title: title.trim(),
            description: description.trim() || undefined,
            type: TaskType.NORMAL,
          });
        } else if (taskType === TaskType.COUNTING) {
          const parsedMaxCount = parseInt(maxCountStr, 10);
          const resolvedTitle = generateCounterTaskTitle(
            action.trim(),
            parsedMaxCount,
            unit.trim(),
            title.trim() || undefined
          );
          newTask = await createTask(userId, {
            title: resolvedTitle,
            description: description.trim() || undefined,
            type: TaskType.COUNTING,
            action: action.trim(),
            unit: unit.trim(),
            maxCount: parsedMaxCount,
          });
        } else if (taskType === TaskType.ACHIEVEMENT) {
          // Phase 6.3 — Achievement task: serialise the mode + picker
          // selection into the appropriate reference field. Cycle
          // detection runs at placement time (BoardWizardTasksStep)
          // because creating the Task itself doesn't place it on any
          // board — there are no parents to form a cycle with yet.
          newTask = await createTask(userId, {
            title: title.trim(),
            description: description.trim() || undefined,
            type: TaskType.ACHIEVEMENT,
            referencedBoardId:
              achievementMode === 'specificBoard' && achievementReferenceId
                ? achievementReferenceId
                : undefined,
            referencedTemplateId:
              achievementMode === 'recurringTemplate' && achievementReferenceId
                ? achievementReferenceId
                : undefined,
          });
        } else {
          // Progress tasks: route through createCompound (compound + isOrdered=true).
          // Each step becomes an inline-created primitive child Task linked via
          // compoundChildren — preserves the "step is independently pool-addable"
          // semantic that legacy progress tasks had.
          const children: CreateCompoundChildEntry[] = steps.map((s) => {
            const trimmedStepTitle = s.title.trim();
            const trimmedAction = s.action.trim();
            const trimmedUnit = s.unit.trim();
            const maxCount = parseInt(s.maxCount, 10);
            const resolvedStepTitle =
              s.type === 'counting'
                ? generateCounterTaskTitle(
                    trimmedAction,
                    maxCount,
                    trimmedUnit,
                    trimmedStepTitle || undefined
                  )
                : trimmedStepTitle;
            return {
              autoCreate: {
                title: resolvedStepTitle,
                type: s.type === 'counting' ? TaskType.COUNTING : TaskType.NORMAL,
                ...(s.type === 'counting'
                  ? { action: trimmedAction, unit: trimmedUnit, maxCount }
                  : {}),
              },
            };
          });
          newTask = await createCompound(userId, {
            title: title.trim(),
            description: description.trim() || undefined,
            operator: OperatorType.AND,
            isOrdered: true,
            children,
          });
        }

        onTaskCreated(newTask);
        resetForm();
      } catch (error) {
        const errorMessage = error instanceof Error ? error.message : 'Unknown error occurred';
        setErrors((prev) => ({ ...prev, general: errorMessage }));
      } finally {
        setIsSubmitting(false);
      }
    },
    [taskType, title, description, action, unit, maxCountStr, steps, userId, onTaskCreated, achievementMode, achievementReferenceId]
  );

  return {
    taskType,
    title,
    description,
    action,
    unit,
    maxCountStr,
    steps,
    errors,
    isSubmitting,
    deriveFromTask,
    achievementMode,
    achievementReferenceId,
    setAchievementMode: handleAchievementModeChange,
    setAchievementReferenceId: handleAchievementReferenceChange,
    setTitle: setTitleClearingError,
    setDescription: setDescriptionClearingError,
    setAction: setActionClearingError,
    setUnit: setUnitClearingError,
    setMaxCountStr: setMaxCountStrClearingError,
    handleTypeChange,
    applyTemplate,
    clearTemplate,
    updateStep,
    addStep,
    removeStep,
    handleSubmit,
  };
}
