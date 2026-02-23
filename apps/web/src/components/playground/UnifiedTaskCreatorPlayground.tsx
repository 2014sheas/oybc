import { useState } from 'react';
import { TaskType, generateCounterTaskTitle, type Task, type TaskStep } from '@oybc/shared';
import { createTask } from '../../db';
import { useTasks, useTaskSteps } from '../../hooks';
import { ProgressStepRow, type StepFormState, createEmptyStep } from './ProgressStepRow';
import { PLAYGROUND_USER_ID, SUCCESS_DISMISS_MS } from './playgroundUtils';
import styles from './UnifiedTaskCreatorPlayground.module.css';

/** Maximum character lengths matching shared validation schemas */
const TITLE_MAX_LENGTH = 200;
const DESCRIPTION_MAX_LENGTH = 1000;
const ACTION_MAX_LENGTH = 50;
const UNIT_MAX_LENGTH = 50;
/** Step title max length for the unified creator */
const STEP_TITLE_MAX_LENGTH = 200;

// To add COMPOUND task type in future: add entry here and define its field config
const TASK_TYPES: { value: TaskType; label: string }[] = [
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: TaskType.PROGRESS, label: 'Progress' },
];

const TYPE_FILTER_TABS: { value: 'all' | TaskType; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: TaskType.PROGRESS, label: 'Progress' },
];

/**
 * Validation error state for the unified task creation form
 */
interface FormErrors {
  title?: string;
  description?: string;
  action?: string;
  unit?: string;
  maxCount?: string;
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
 * Returns CSS class for character count based on proximity to limit.
 *
 * @param current - Current character count
 * @param max - Maximum allowed characters
 * @returns CSS class name string
 */
function getCharCountClass(current: number, max: number): string {
  if (current > max) return `${styles.charCount} ${styles.charCountError}`;
  if (current >= max * 0.9) return `${styles.charCount} ${styles.charCountWarning}`;
  return styles.charCount;
}

/**
 * Validates the unified task creation form.
 *
 * @param type - The task type selected
 * @param title - The task title
 * @param description - The optional task description
 * @param action - Action for counting tasks
 * @param unit - Unit for counting tasks
 * @param maxCountStr - Max count string for counting tasks
 * @param steps - Steps for progress tasks
 * @returns Object containing any validation errors
 */
function validateForm(
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
      const errs: {
        title?: string;
        action?: string;
        unit?: string;
        maxCount?: string;
      } = {};

      const trimmedStepTitle = step.title.trim();
      if (step.type !== 'counting' && trimmedStepTitle.length === 0) {
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
  }

  return errors;
}

/**
 * ProgressStepList - Reactive step list display for a progress task card
 *
 * @param taskId - The task ID to fetch steps for
 */
function ProgressStepList({ taskId }: { taskId: string }): React.ReactElement {
  const steps = useTaskSteps(taskId) ?? [];
  if (steps.length === 0) return <span className={styles.taskMeta}>No steps</span>;
  return (
    <ol className={styles.libraryStepList}>
      {steps.map((step: TaskStep) => (
        <li key={step.id} className={styles.libraryStepItem}>
          <span className={styles.libraryStepTitle}>{step.title}</span>
          <span className={`${styles.typeBadge} ${styles[`typeBadge${step.type.charAt(0).toUpperCase()}${step.type.slice(1)}`]}`}>
            {step.type.toUpperCase()}
          </span>
          {step.type === 'counting' && step.action && step.unit && step.maxCount !== undefined && (
            <span className={styles.libraryStepMeta}>{step.action} {step.maxCount} {step.unit}</span>
          )}
        </li>
      ))}
    </ol>
  );
}

/**
 * TaskLibraryCard - Displays a single task in the task library
 *
 * @param task - The task to display
 */
function TaskLibraryCard({ task }: { task: Task }): React.ReactElement {
  return (
    <div className={styles.taskCard}>
      <div className={styles.taskCardHeader}>
        <span className={styles.taskTitle}>{task.title}</span>
        <span className={`${styles.typeBadge} ${styles[`typeBadge${task.type.charAt(0).toUpperCase()}${task.type.slice(1)}`]}`}>
          {task.type.toUpperCase()}
        </span>
      </div>
      {task.description && (
        <p className={styles.taskDescription}>{task.description}</p>
      )}
      {task.type === TaskType.COUNTING && task.action && task.unit && task.maxCount && (
        <p className={styles.taskMeta}>
          {task.action} {task.unit} (max: {task.maxCount})
        </p>
      )}
      {task.type === TaskType.PROGRESS && (
        <ProgressStepList taskId={task.id} />
      )}
    </div>
  );
}

/**
 * UnifiedTaskCreatorPlayground - Playground feature for creating any task type
 *
 * Provides a unified form to create Normal, Counting, or Progress tasks,
 * with a reactive task library that filters by type. Tasks are stored in
 * the real Dexie database with reactive updates.
 */
export function UnifiedTaskCreatorPlayground(): React.ReactElement {
  const [taskType, setTaskType] = useState<TaskType>(TaskType.NORMAL);
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  // Counting fields
  const [action, setAction] = useState('');
  const [unit, setUnit] = useState('');
  const [maxCountStr, setMaxCountStr] = useState('');
  // Progress fields
  const [steps, setSteps] = useState<StepFormState[]>([createEmptyStep()]);
  // Form state
  const [errors, setErrors] = useState<FormErrors>({});
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  // Library filter
  const [filterType, setFilterType] = useState<'all' | TaskType>('all');

  // Reactive task list - auto-updates when database changes
  const allTasks = useTasks(PLAYGROUND_USER_ID) ?? [];

  const filteredTasks = filterType === 'all'
    ? allTasks
    : allTasks.filter((t: Task) => t.type === filterType);

  /**
   * Resets the form to its default state (type = Normal, empty fields).
   */
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

  /**
   * Handles task type change, clearing type-specific field errors.
   *
   * @param newType - The newly selected task type
   */
  function handleTypeChange(newType: TaskType): void {
    setTaskType(newType);
    setErrors((prev) => ({
      ...prev,
      action: undefined,
      unit: undefined,
      maxCount: undefined,
      steps: undefined,
    }));
  }

  /**
   * Updates a specific step's field value and clears associated errors.
   *
   * @param stepId - The step form ID to update
   * @param field - The field name to update
   * @param value - The new value
   */
  function updateStep(stepId: string, field: keyof StepFormState, value: string): void {
    setSteps((prev) =>
      prev.map((s) => (s.id === stepId ? { ...s, [field]: value } : s))
    );
    if (errors.steps?.[stepId]) {
      setErrors((prev) => {
        const newStepErrors = { ...prev.steps };
        if (newStepErrors[stepId]) {
          newStepErrors[stepId] = { ...newStepErrors[stepId], [field]: undefined };
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
   * Handles form submission to create a new task of the selected type.
   * Validates inputs, persists to Dexie, resets the form,
   * and shows a success message that auto-dismisses after 3s.
   */
  async function handleSubmit(e: React.FormEvent): Promise<void> {
    e.preventDefault();

    const validationErrors = validateForm(
      taskType,
      title,
      description,
      action,
      unit,
      maxCountStr,
      steps
    );
    setErrors(validationErrors);

    if (Object.keys(validationErrors).length > 0) {
      return;
    }

    setIsSubmitting(true);

    try {
      if (taskType === TaskType.NORMAL) {
        await createTask(PLAYGROUND_USER_ID, {
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
        await createTask(PLAYGROUND_USER_ID, {
          title: resolvedTitle,
          description: description.trim() || undefined,
          type: TaskType.COUNTING,
          action: action.trim(),
          unit: unit.trim(),
          maxCount: parsedMaxCount,
        });
      } else if (taskType === TaskType.PROGRESS) {
        await createTask(PLAYGROUND_USER_ID, {
          title: title.trim(),
          description: description.trim() || undefined,
          type: TaskType.PROGRESS,
          steps: steps.map((s) => {
            const resolvedTitle =
              s.type === 'counting'
                ? generateCounterTaskTitle(s.action, parseInt(s.maxCount, 10), s.unit, s.title || undefined)
                : s.title.trim();
            return {
              title: resolvedTitle,
              type: s.type === 'counting' ? TaskType.COUNTING : TaskType.NORMAL,
              ...(s.type === 'counting'
                ? {
                    action: s.action.trim(),
                    unit: s.unit.trim(),
                    maxCount: parseInt(s.maxCount, 10),
                  }
                : {}),
            };
          }),
        });
      }

      resetForm();

      setSuccessMessage('Task created!');
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
      {/* Part 1: Unified Task Creator */}
      <section className={styles.section}>
        <h4 className={styles.sectionTitle}>Create Task</h4>

        <form className={styles.form} onSubmit={handleSubmit}>
          {/* Type Selector */}
          <div className={styles.fieldGroup}>
            <label className={styles.label}>
              Type<span className={styles.required}>*</span>
            </label>
            <div className={styles.typeSelector}>
              {TASK_TYPES.map((t) => (
                <button
                  key={t.value}
                  type="button"
                  className={`${styles.typeButton} ${taskType === t.value ? styles.typeButtonActive : ''}`}
                  onClick={() => handleTypeChange(t.value)}
                >
                  {t.label}
                </button>
              ))}
            </div>
          </div>

          {/* Title */}
          <div className={styles.fieldGroup}>
            <label className={styles.label} htmlFor="unified-task-title">
              Title{taskType !== TaskType.COUNTING && <span className={styles.required}>*</span>}
            </label>
            <input
              id="unified-task-title"
              type="text"
              className={`${styles.input} ${errors.title ? styles.inputError : ''}`}
              value={title}
              onChange={(e) => {
                setTitle(e.target.value);
                if (errors.title) {
                  setErrors((prev) => ({ ...prev, title: undefined }));
                }
              }}
              placeholder={taskType === TaskType.COUNTING ? 'Auto-generated if blank (e.g., "Run 26 miles")' : 'Enter task title'}
              maxLength={TITLE_MAX_LENGTH + 1}
            />
            <span className={getCharCountClass(title.length, TITLE_MAX_LENGTH)}>
              {title.length}/{TITLE_MAX_LENGTH}
            </span>
            {errors.title && (
              <span className={styles.fieldError}>{errors.title}</span>
            )}
          </div>

          {/* Description */}
          <div className={styles.fieldGroup}>
            <label className={styles.label} htmlFor="unified-task-description">
              Description
            </label>
            <textarea
              id="unified-task-description"
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
            <span className={getCharCountClass(description.length, DESCRIPTION_MAX_LENGTH)}>
              {description.length}/{DESCRIPTION_MAX_LENGTH}
            </span>
            {errors.description && (
              <span className={styles.fieldError}>{errors.description}</span>
            )}
          </div>

          {/* Counting Fields (conditional) */}
          {taskType === TaskType.COUNTING && (
            <div className={styles.countingFields}>
              {/* Action */}
              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="unified-task-action">
                  Action<span className={styles.required}>*</span>
                </label>
                <input
                  id="unified-task-action"
                  type="text"
                  className={`${styles.input} ${errors.action ? styles.inputError : ''}`}
                  value={action}
                  onChange={(e) => {
                    setAction(e.target.value);
                    if (errors.action) {
                      setErrors((prev) => ({ ...prev, action: undefined }));
                    }
                  }}
                  placeholder='e.g., "Run"'
                  maxLength={ACTION_MAX_LENGTH}
                />
                {errors.action && (
                  <span className={styles.fieldError}>{errors.action}</span>
                )}
              </div>

              {/* Max Count */}
              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="unified-task-maxcount">
                  Max Count<span className={styles.required}>*</span>
                </label>
                <input
                  id="unified-task-maxcount"
                  type="number"
                  className={`${styles.input} ${errors.maxCount ? styles.inputError : ''}`}
                  value={maxCountStr}
                  onChange={(e) => {
                    setMaxCountStr(e.target.value);
                    if (errors.maxCount) {
                      setErrors((prev) => ({ ...prev, maxCount: undefined }));
                    }
                  }}
                  placeholder="e.g., 26"
                  min="1"
                />
                {errors.maxCount && (
                  <span className={styles.fieldError}>{errors.maxCount}</span>
                )}
              </div>

              {/* Unit */}
              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="unified-task-unit">
                  Unit<span className={styles.required}>*</span>
                </label>
                <input
                  id="unified-task-unit"
                  type="text"
                  className={`${styles.input} ${errors.unit ? styles.inputError : ''}`}
                  value={unit}
                  onChange={(e) => {
                    setUnit(e.target.value);
                    if (errors.unit) {
                      setErrors((prev) => ({ ...prev, unit: undefined }));
                    }
                  }}
                  placeholder='e.g., "miles"'
                  maxLength={UNIT_MAX_LENGTH}
                />
                {errors.unit && (
                  <span className={styles.fieldError}>{errors.unit}</span>
                )}
              </div>
            </div>
          )}

          {/* Progress Steps (conditional) */}
          {taskType === TaskType.PROGRESS && (
            <div className={styles.stepsSection}>
              <span className={styles.stepsHeader}>Steps</span>

              <div className={styles.stepsList}>
                {steps.map((step, index) => (
                  <ProgressStepRow
                    key={step.id}
                    index={index}
                    idPrefix={`unified-step-${step.id}`}
                    step={step}
                    errors={errors.steps?.[step.id]}
                    canRemove={steps.length > 1}
                    stepTitleMaxLength={STEP_TITLE_MAX_LENGTH}
                    onFieldChange={(field, value) =>
                      updateStep(step.id, field, value)
                    }
                    onRemove={() => removeStep(step.id)}
                  />
                ))}
              </div>

              <button
                type="button"
                className={styles.addStepButton}
                onClick={addStep}
              >
                + Add Step
              </button>
            </div>
          )}

          {/* Submit */}
          <button
            type="submit"
            className={styles.submitButton}
            disabled={isSubmitting}
          >
            {isSubmitting ? 'Creating...' : 'Create Task'}
          </button>
        </form>

        {/* Success Message */}
        {successMessage && (
          <div className={styles.successMessage}>{successMessage}</div>
        )}

        {/* General Error */}
        {errors.general && (
          <div className={styles.errorMessage}>{errors.general}</div>
        )}
      </section>

      {/* Part 2: Task Library */}
      <section className={styles.section}>
        <h4 className={styles.sectionTitle}>Task Library</h4>

        {/* Filter Tabs */}
        <div className={styles.filterTabs}>
          {TYPE_FILTER_TABS.map((tab) => (
            <button
              key={tab.value}
              type="button"
              className={`${styles.filterTab} ${filterType === tab.value ? styles.filterTabActive : ''}`}
              onClick={() => setFilterType(tab.value)}
            >
              {tab.label}
            </button>
          ))}
        </div>

        {/* Task List */}
        {filteredTasks.length === 0 ? (
          <p className={styles.emptyState}>No tasks yet — create one above</p>
        ) : (
          <div className={styles.taskList}>
            {filteredTasks.map((task: Task) => (
              <TaskLibraryCard key={task.id} task={task} />
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
