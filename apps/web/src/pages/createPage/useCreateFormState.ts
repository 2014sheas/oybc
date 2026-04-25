import { useCallback, useState } from 'react';
import { TaskType, generateCounterTaskTitle, type Task } from '@oybc/shared';
import { createTask } from '../../db/operations/tasks';
import { type StepFormState, createEmptyStep } from '../../components/progressStepUtils';
/** Union of TaskType values plus 'composite' for the Create-New tab type selector. */
export type TaskTypeOrComposite = TaskType | 'composite';
export const COMPOSITE_TYPE = 'composite' as const;

// ─── Constants (shared with CreatePage UI) ────────────────────────────────────

export const TITLE_MAX_LENGTH = 200;
export const DESCRIPTION_MAX_LENGTH = 1000;
export const ACTION_MAX_LENGTH = 50;
export const UNIT_MAX_LENGTH = 50;
export const STEP_TITLE_MAX_LENGTH = 200;

// ─── Error shape ──────────────────────────────────────────────────────────────

export interface FormErrors {
  title?: string;
  description?: string;
  action?: string;
  unit?: string;
  maxCount?: string;
  steps?: Record<string, { title?: string; action?: string; unit?: string; maxCount?: string }>;
  general?: string;
}

// ─── Validation ──────────────────────────────────────────────────────────────

/**
 * Pure form-validation function. Returns an error object keyed by
 * field; empty object means "valid". Kept exported so an outside
 * caller (e.g. an integration test, or a future submit confirmation
 * flow) can validate without instantiating the hook.
 */
export function validateForm(
  type: TaskType,
  title: string,
  description: string,
  action: string,
  unit: string,
  maxCountStr: string,
  steps: StepFormState[]
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

  if (type === TaskType.PROGRESS) {
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

  // Setters (with inline error-clearing where appropriate)
  setTitle: (v: string) => void;
  setDescription: (v: string) => void;
  setAction: (v: string) => void;
  setUnit: (v: string) => void;
  setMaxCountStr: (v: string) => void;
  handleTypeChange: (v: TaskTypeOrComposite) => void;

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

  /**
   * Wrap a plain setter so editing a field also clears its own error —
   * matches the pattern the original CreatePage used inline for every
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
    setErrors((prev) => ({
      ...prev,
      action: undefined,
      unit: undefined,
      maxCount: undefined,
      steps: undefined,
    }));
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
  }

  const handleSubmit = useCallback(
    async (e: React.FormEvent): Promise<void> => {
      e.preventDefault();

      if (taskType === COMPOSITE_TYPE || !userId) return;

      const validationErrors = validateForm(taskType, title, description, action, unit, maxCountStr, steps);
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
        } else {
          newTask = await createTask(userId, {
            title: title.trim(),
            description: description.trim() || undefined,
            type: TaskType.PROGRESS,
            steps: steps.map((s) => {
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
                title: resolvedStepTitle,
                type: s.type === 'counting' ? TaskType.COUNTING : TaskType.NORMAL,
                ...(s.type === 'counting'
                  ? { action: trimmedAction, unit: trimmedUnit, maxCount }
                  : {}),
              };
            }),
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
    [taskType, title, description, action, unit, maxCountStr, steps, userId, onTaskCreated]
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
    setTitle: setTitleClearingError,
    setDescription: setDescriptionClearingError,
    setAction: setActionClearingError,
    setUnit: setUnitClearingError,
    setMaxCountStr: setMaxCountStrClearingError,
    handleTypeChange,
    updateStep,
    addStep,
    removeStep,
    handleSubmit,
  };
}
