import { useState } from 'react';
import { TaskType, type Task, type TaskStep } from '@oybc/shared';
import { createTask } from '../../db';
import { useTasks, useTaskSteps } from '../../hooks';
import styles from './ProgressTaskCreationPlayground.module.css';

/** Maximum character lengths matching shared validation schemas */
const TITLE_MAX_LENGTH = 200;
const DESCRIPTION_MAX_LENGTH = 1000;
const ACTION_MAX_LENGTH = 50;
const UNIT_MAX_LENGTH = 50;

/** Mock user ID for Playground testing */
const PLAYGROUND_USER_ID = 'playground-user-1';

/** Duration in ms before success message auto-dismisses */
const SUCCESS_DISMISS_MS = 3000;

/**
 * Form state for a single step in the progress task creation form
 */
interface StepFormState {
  id: string;
  title: string;
  type: 'normal' | 'counting';
  action: string;
  unit: string;
  maxCount: string;
}

/**
 * Validation error state for the progress task creation form
 */
interface FormErrors {
  title?: string;
  description?: string;
  steps?: Record<
    string,
    {
      title?: string;
      action?: string;
      unit?: string;
      maxCount?: string;
    }
  >;
  general?: string;
}

/**
 * Generates a unique client-side ID for form step tracking.
 *
 * @returns A unique string ID
 */
function generateFormId(): string {
  return crypto.randomUUID();
}

/**
 * Creates a new empty step form state.
 *
 * @returns A fresh StepFormState with default values
 */
function createEmptyStep(): StepFormState {
  return {
    id: generateFormId(),
    title: '',
    type: 'normal',
    action: '',
    unit: '',
    maxCount: '',
  };
}

/**
 * Returns CSS class for character count based on proximity to limit.
 *
 * @param current - Current character count
 * @param max - Maximum allowed characters
 * @returns CSS class name string
 */
function getCharCountClass(current: number, max: number): string {
  if (current > max) return `${styles.charCount} ${styles.charCountError}`;
  if (current >= max * 0.9)
    return `${styles.charCount} ${styles.charCountWarning}`;
  return styles.charCount;
}

/**
 * Validates the progress task creation form fields.
 *
 * @param title - The task title
 * @param description - The optional task description
 * @param steps - The array of step form states
 * @returns Object containing any validation errors
 */
function validateForm(
  title: string,
  description: string,
  steps: StepFormState[]
): FormErrors {
  const errors: FormErrors = {};

  const trimmedTitle = title.trim();
  if (trimmedTitle.length === 0) {
    errors.title = 'Title is required';
  } else if (trimmedTitle.length > TITLE_MAX_LENGTH) {
    errors.title = `Title must be ${TITLE_MAX_LENGTH} characters or less`;
  }

  if (description.length > DESCRIPTION_MAX_LENGTH) {
    errors.description = `Description must be ${DESCRIPTION_MAX_LENGTH} characters or less`;
  }

  const stepErrors: FormErrors['steps'] = {};
  let hasStepErrors = false;

  for (const step of steps) {
    const errs: {
      title?: string;
      action?: string;
      unit?: string;
      maxCount?: string;
    } = {};

    const trimmedStepTitle = step.title.trim();
    if (trimmedStepTitle.length === 0) {
      errs.title = 'Step title is required';
    } else if (trimmedStepTitle.length > TITLE_MAX_LENGTH) {
      errs.title = `Step title must be ${TITLE_MAX_LENGTH} characters or less`;
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

  return errors;
}

/**
 * Formats an ISO8601 date string for display.
 *
 * @param isoString - ISO8601 date string
 * @returns Human-readable date string
 */
function formatDate(isoString: string): string {
  return new Date(isoString).toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

/**
 * ProgressTaskRow - Displays a single progress task with its steps
 *
 * Uses the useTaskSteps hook internally for reactive per-task step display.
 *
 * @param task - The task to display
 */
function ProgressTaskRow({ task }: { task: Task }): React.ReactElement {
  const steps = useTaskSteps(task.id) ?? [];

  return (
    <div className={styles.taskRow}>
      <div className={styles.taskHeader}>
        <span className={styles.taskTitle}>{task.title}</span>
        <span className={styles.badge}>PROGRESS</span>
        <span className={styles.stepCount}>
          {steps.length} step{steps.length !== 1 ? 's' : ''}
        </span>
      </div>
      {task.description && (
        <p className={styles.taskDescription}>{task.description}</p>
      )}
      <p className={styles.taskDate}>
        Created: {formatDate(task.createdAt)}
      </p>
      {steps.length > 0 && (
        <ol className={styles.displayStepList}>
          {steps.map((step: TaskStep) => (
            <li key={step.id} className={styles.stepItem}>
              <span className={styles.stepTitle}>{step.title}</span>
              <span className={styles.stepTypeBadge}>
                {step.type.toUpperCase()}
              </span>
              {step.type === 'counting' &&
                step.action &&
                step.unit &&
                step.maxCount && (
                  <span className={styles.stepCounting}>
                    {step.action} {step.maxCount} {step.unit}
                  </span>
                )}
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}

/**
 * ProgressTaskCreationPlayground - Playground feature for creating PROGRESS tasks
 *
 * Provides a form to create progress tasks with multiple sub-steps,
 * stored in the real Dexie database. Includes a reactive task list
 * that updates automatically and success feedback.
 */
export function ProgressTaskCreationPlayground(): React.ReactElement {
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [steps, setSteps] = useState<StepFormState[]>([createEmptyStep()]);
  const [errors, setErrors] = useState<FormErrors>({});
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);

  // Reactive task list - auto-updates when database changes
  const allTasks = useTasks(PLAYGROUND_USER_ID);

  // Filter to only show PROGRESS tasks
  const progressTasks = allTasks.filter(
    (t: Task) => t.type === TaskType.PROGRESS
  );

  /**
   * Updates a specific step's field value and clears associated errors.
   *
   * @param stepId - The step form ID to update
   * @param field - The field name to update
   * @param value - The new value
   */
  function updateStep(
    stepId: string,
    field: keyof StepFormState,
    value: string
  ): void {
    setSteps((prev) =>
      prev.map((s) => (s.id === stepId ? { ...s, [field]: value } : s))
    );
    // Clear field error for this step
    if (errors.steps?.[stepId]) {
      setErrors((prev) => {
        const newStepErrors = { ...prev.steps };
        if (newStepErrors[stepId]) {
          newStepErrors[stepId] = { ...newStepErrors[stepId], [field]: undefined };
          // If no remaining errors for this step, remove the entry
          if (Object.values(newStepErrors[stepId]).every((v) => v === undefined)) {
            delete newStepErrors[stepId];
          }
        }
        const hasStepErrors = Object.keys(newStepErrors).length > 0;
        return {
          ...prev,
          steps: hasStepErrors ? newStepErrors : undefined,
        };
      });
    }
  }

  /**
   * Adds a new empty step to the form.
   */
  function addStep(): void {
    setSteps((prev) => [...prev, createEmptyStep()]);
  }

  /**
   * Removes a step from the form by ID. Won't remove the last step.
   *
   * @param stepId - The step form ID to remove
   */
  function removeStep(stepId: string): void {
    if (steps.length <= 1) return;
    setSteps((prev) => prev.filter((s) => s.id !== stepId));
    // Clear errors for the removed step
    if (errors.steps?.[stepId]) {
      setErrors((prev) => {
        const newStepErrors = { ...prev.steps };
        delete newStepErrors[stepId];
        const hasStepErrors = Object.keys(newStepErrors).length > 0;
        return {
          ...prev,
          steps: hasStepErrors ? newStepErrors : undefined,
        };
      });
    }
  }

  /**
   * Handles form submission to create a new PROGRESS task.
   * Validates inputs, creates the task with steps in Dexie, clears the form,
   * and shows a success message that auto-dismisses.
   */
  async function handleSubmit(e: React.FormEvent): Promise<void> {
    e.preventDefault();

    // Validate
    const validationErrors = validateForm(title, description, steps);
    setErrors(validationErrors);

    if (Object.keys(validationErrors).length > 0) {
      return;
    }

    setIsSubmitting(true);

    try {
      const input = {
        title: title.trim(),
        description: description.trim() || undefined,
        type: TaskType.PROGRESS as const,
        steps: steps.map((s) => ({
          title: s.title.trim(),
          type: s.type === 'counting' ? TaskType.COUNTING : TaskType.NORMAL,
          ...(s.type === 'counting'
            ? {
                action: s.action.trim(),
                unit: s.unit.trim(),
                maxCount: Number(s.maxCount),
              }
            : {}),
        })),
      };

      await createTask(PLAYGROUND_USER_ID, input);

      // Clear form
      setTitle('');
      setDescription('');
      setSteps([createEmptyStep()]);
      setErrors({});

      // Show success message
      setSuccessMessage('Progress task created!');
      setTimeout(() => {
        setSuccessMessage(null);
      }, SUCCESS_DISMISS_MS);
    } catch (error) {
      const errorMessage =
        error instanceof Error ? error.message : 'Unknown error occurred';
      setErrors((prev) => ({ ...prev, general: errorMessage }));
    } finally {
      setIsSubmitting(false);
    }
  }

  return (
    <div className={styles.container}>
      {/* Progress Task Creation Form */}
      <form className={styles.form} onSubmit={handleSubmit}>
        {/* Title Field */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="progress-task-title">
            Title<span className={styles.required}>*</span>
          </label>
          <input
            id="progress-task-title"
            type="text"
            className={`${styles.input} ${errors.title ? styles.inputError : ''}`}
            value={title}
            onChange={(e) => {
              setTitle(e.target.value);
              if (errors.title) {
                setErrors((prev) => ({ ...prev, title: undefined }));
              }
            }}
            placeholder="Enter progress task title"
            maxLength={TITLE_MAX_LENGTH + 1}
          />
          <span className={getCharCountClass(title.length, TITLE_MAX_LENGTH)}>
            {title.length}/{TITLE_MAX_LENGTH}
          </span>
          {errors.title && (
            <span className={styles.fieldError}>{errors.title}</span>
          )}
        </div>

        {/* Description Field */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="progress-task-description">
            Description
          </label>
          <textarea
            id="progress-task-description"
            className={`${styles.input} ${styles.textarea} ${errors.description ? styles.inputError : ''}`}
            value={description}
            onChange={(e) => {
              setDescription(e.target.value);
              if (errors.description) {
                setErrors((prev) => ({ ...prev, description: undefined }));
              }
            }}
            placeholder="Enter task description (optional)"
            maxLength={DESCRIPTION_MAX_LENGTH + 1}
          />
          <span
            className={getCharCountClass(
              description.length,
              DESCRIPTION_MAX_LENGTH
            )}
          >
            {description.length}/{DESCRIPTION_MAX_LENGTH}
          </span>
          {errors.description && (
            <span className={styles.fieldError}>{errors.description}</span>
          )}
        </div>

        {/* Steps Section */}
        <div className={styles.stepsSection}>
          <span className={styles.stepsHeader}>Steps</span>

          <div className={styles.stepsList}>
            {steps.map((step, index) => {
              const stepErrors = errors.steps?.[step.id];
              return (
                <div key={step.id} className={styles.stepRow}>
                  <div className={styles.stepHeader}>
                    <span className={styles.stepNumber}>
                      Step {index + 1}
                    </span>
                    <button
                      type="button"
                      className={styles.removeStepButton}
                      onClick={() => removeStep(step.id)}
                      disabled={steps.length <= 1}
                    >
                      Remove
                    </button>
                  </div>

                  <div className={styles.stepFields}>
                    {/* Step Title */}
                    <div className={styles.fieldGroup}>
                      <label
                        className={styles.label}
                        htmlFor={`step-title-${step.id}`}
                      >
                        Step Title<span className={styles.required}>*</span>
                      </label>
                      <input
                        id={`step-title-${step.id}`}
                        type="text"
                        className={`${styles.input} ${stepErrors?.title ? styles.inputError : ''}`}
                        value={step.title}
                        onChange={(e) =>
                          updateStep(step.id, 'title', e.target.value)
                        }
                        placeholder="Enter step title"
                        maxLength={TITLE_MAX_LENGTH + 1}
                      />
                      <span
                        className={getCharCountClass(
                          step.title.length,
                          TITLE_MAX_LENGTH
                        )}
                      >
                        {step.title.length}/{TITLE_MAX_LENGTH}
                      </span>
                      {stepErrors?.title && (
                        <span className={styles.fieldError}>
                          {stepErrors.title}
                        </span>
                      )}
                    </div>

                    {/* Step Type */}
                    <div className={styles.fieldGroup}>
                      <label
                        className={styles.label}
                        htmlFor={`step-type-${step.id}`}
                      >
                        Type
                      </label>
                      <select
                        id={`step-type-${step.id}`}
                        className={styles.stepTypeSelect}
                        value={step.type}
                        onChange={(e) =>
                          updateStep(
                            step.id,
                            'type',
                            e.target.value as 'normal' | 'counting'
                          )
                        }
                      >
                        <option value="normal">Normal</option>
                        <option value="counting">Counting</option>
                      </select>
                    </div>

                    {/* Counting Fields (conditional) */}
                    {step.type === 'counting' && (
                      <div className={styles.countingFields}>
                        {/* Action */}
                        <div className={styles.fieldGroup}>
                          <label
                            className={styles.label}
                            htmlFor={`step-action-${step.id}`}
                          >
                            Action
                            <span className={styles.required}>*</span>
                          </label>
                          <input
                            id={`step-action-${step.id}`}
                            type="text"
                            className={`${styles.input} ${stepErrors?.action ? styles.inputError : ''}`}
                            value={step.action}
                            onChange={(e) =>
                              updateStep(step.id, 'action', e.target.value)
                            }
                            placeholder='e.g., "Read"'
                            maxLength={ACTION_MAX_LENGTH}
                          />
                          {stepErrors?.action && (
                            <span className={styles.fieldError}>
                              {stepErrors.action}
                            </span>
                          )}
                        </div>

                        {/* Unit */}
                        <div className={styles.fieldGroup}>
                          <label
                            className={styles.label}
                            htmlFor={`step-unit-${step.id}`}
                          >
                            Unit
                            <span className={styles.required}>*</span>
                          </label>
                          <input
                            id={`step-unit-${step.id}`}
                            type="text"
                            className={`${styles.input} ${stepErrors?.unit ? styles.inputError : ''}`}
                            value={step.unit}
                            onChange={(e) =>
                              updateStep(step.id, 'unit', e.target.value)
                            }
                            placeholder='e.g., "pages"'
                            maxLength={UNIT_MAX_LENGTH}
                          />
                          {stepErrors?.unit && (
                            <span className={styles.fieldError}>
                              {stepErrors.unit}
                            </span>
                          )}
                        </div>

                        {/* Max Count */}
                        <div className={styles.fieldGroup}>
                          <label
                            className={styles.label}
                            htmlFor={`step-maxcount-${step.id}`}
                          >
                            Max Count
                            <span className={styles.required}>*</span>
                          </label>
                          <input
                            id={`step-maxcount-${step.id}`}
                            type="number"
                            className={`${styles.input} ${stepErrors?.maxCount ? styles.inputError : ''}`}
                            value={step.maxCount}
                            onChange={(e) =>
                              updateStep(step.id, 'maxCount', e.target.value)
                            }
                            placeholder="e.g., 100"
                            min="1"
                          />
                          {stepErrors?.maxCount && (
                            <span className={styles.fieldError}>
                              {stepErrors.maxCount}
                            </span>
                          )}
                        </div>
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>

          <button
            type="button"
            className={styles.addStepButton}
            onClick={addStep}
          >
            + Add Step
          </button>
        </div>

        {/* Submit Button */}
        <button
          type="submit"
          className={styles.submitButton}
          disabled={isSubmitting}
        >
          {isSubmitting ? 'Creating...' : 'Create Progress Task'}
        </button>
      </form>

      {/* Success Message */}
      {successMessage && (
        <div className={styles.successMessage}>{successMessage}</div>
      )}

      {/* General Error Message */}
      {errors.general && (
        <div className={styles.errorMessage}>{errors.general}</div>
      )}

      {/* Progress Task List */}
      <div className={styles.taskListSection}>
        <h4 className={styles.taskListTitle}>Created Progress Tasks</h4>

        {progressTasks.length === 0 ? (
          <p className={styles.emptyState}>No progress tasks yet.</p>
        ) : (
          <div className={styles.taskList}>
            {progressTasks.map((task: Task) => (
              <ProgressTaskRow key={task.id} task={task} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
