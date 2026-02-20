import { useState } from 'react';
import { TaskType, CreateTaskInputSchema, type Task } from '@oybc/shared';
import { createTask } from '../db';
import { useTasks } from '../hooks';
import { generateCounterTaskTitle } from '@oybc/shared';
import styles from './TaskCreationPlayground.module.css';

/** Maximum character lengths matching shared validation schemas */
const ACTION_MAX_LENGTH = 50;
const UNIT_MAX_LENGTH = 50;
const TITLE_MAX_LENGTH = 200;
const DESCRIPTION_MAX_LENGTH = 1000;

/** Mock user ID for Playground testing */
const PLAYGROUND_USER_ID = 'playground-user-1';

/** Duration in ms before success message auto-dismisses */
const SUCCESS_DISMISS_MS = 3000;

/**
 * Validation error state for the counter task creation form
 */
interface FormErrors {
  action?: string;
  unit?: string;
  maxCount?: string;
  title?: string;
  description?: string;
}

/**
 * Validates the counter task creation form fields.
 *
 * @param action - The action verb
 * @param unit - The unit of measurement
 * @param maxCountStr - The max count as a string from the input
 * @param title - The optional custom title
 * @param description - The optional description
 * @returns Object containing any validation errors
 */
function validateForm(
  action: string,
  unit: string,
  maxCountStr: string,
  title: string,
  description: string
): FormErrors {
  const errors: FormErrors = {};

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

  if (title.length > TITLE_MAX_LENGTH) {
    errors.title = `Title must be ${TITLE_MAX_LENGTH} characters or less`;
  }

  if (description.length > DESCRIPTION_MAX_LENGTH) {
    errors.description = `Description must be ${DESCRIPTION_MAX_LENGTH} characters or less`;
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
 * CounterTaskCreationPlayground - Playground feature for creating COUNTING tasks
 *
 * Provides a form to create counter tasks stored in the real Dexie database,
 * a reactive task list that updates automatically, and success feedback.
 * Only supports COUNTING task type.
 */
export function CounterTaskCreationPlayground(): React.ReactElement {
  const [action, setAction] = useState('');
  const [unit, setUnit] = useState('');
  const [maxCountStr, setMaxCountStr] = useState('');
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [errors, setErrors] = useState<FormErrors>({});
  const [showSuccess, setShowSuccess] = useState(false);
  const [submitError, setSubmitError] = useState('');

  // Reactive task list - auto-updates when database changes
  const allTasks = useTasks(PLAYGROUND_USER_ID);

  // Filter to only show COUNTING tasks
  const counterTasks = allTasks.filter((t: Task) => t.type === TaskType.COUNTING);

  /**
   * Handles form submission to create a new COUNTING task.
   * Validates inputs, creates the task in Dexie, clears the form,
   * and shows a success message that auto-dismisses.
   */
  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSubmitError('');

    // Validate
    const validationErrors = validateForm(action, unit, maxCountStr, title, description);
    setErrors(validationErrors);

    if (Object.keys(validationErrors).length > 0) {
      return;
    }

    try {
      const parsedMaxCount = parseInt(maxCountStr, 10);
      const generatedTitle = generateCounterTaskTitle(action, parsedMaxCount, unit, title);

      // Validate with shared schema
      const input = {
        title: generatedTitle,
        description: description.trim() || undefined,
        type: TaskType.COUNTING,
        action: action.trim(),
        unit: unit.trim(),
        maxCount: parsedMaxCount,
      };

      const result = CreateTaskInputSchema.safeParse(input);
      if (!result.success) {
        setSubmitError(result.error.issues.map((i) => i.message).join(', '));
        return;
      }

      // Create task in Dexie
      await createTask(PLAYGROUND_USER_ID, input);

      // Clear form
      setAction('');
      setUnit('');
      setMaxCountStr('');
      setTitle('');
      setDescription('');
      setErrors({});

      // Show success message
      setShowSuccess(true);
      setTimeout(() => {
        setShowSuccess(false);
      }, SUCCESS_DISMISS_MS);
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error occurred';
      setSubmitError(errorMessage);
    }
  }

  return (
    <div className={styles.container}>
      {/* Counter Task Creation Form */}
      <form className={styles.form} onSubmit={handleSubmit}>
        {/* Action Field */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="counter-task-action">
            Action<span className={styles.required}>*</span>
          </label>
          <input
            id="counter-task-action"
            type="text"
            className={`${styles.input} ${errors.action ? styles.inputError : ''}`}
            value={action}
            onChange={(e) => {
              setAction(e.target.value);
              if (errors.action) {
                setErrors((prev) => ({ ...prev, action: undefined }));
              }
            }}
            placeholder='e.g., "Read"'
            maxLength={ACTION_MAX_LENGTH}
          />
          {errors.action && (
            <span className={styles.fieldError}>{errors.action}</span>
          )}
        </div>

        {/* Max Count Field */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="counter-task-maxcount">
            Max Count<span className={styles.required}>*</span>
          </label>
          <input
            id="counter-task-maxcount"
            type="number"
            className={`${styles.input} ${errors.maxCount ? styles.inputError : ''}`}
            value={maxCountStr}
            onChange={(e) => {
              setMaxCountStr(e.target.value);
              if (errors.maxCount) {
                setErrors((prev) => ({ ...prev, maxCount: undefined }));
              }
            }}
            placeholder="e.g., 100"
            min="1"
          />
          {errors.maxCount && (
            <span className={styles.fieldError}>{errors.maxCount}</span>
          )}
        </div>

        {/* Unit Field */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="counter-task-unit">
            Unit<span className={styles.required}>*</span>
          </label>
          <input
            id="counter-task-unit"
            type="text"
            className={`${styles.input} ${errors.unit ? styles.inputError : ''}`}
            value={unit}
            onChange={(e) => {
              setUnit(e.target.value);
              if (errors.unit) {
                setErrors((prev) => ({ ...prev, unit: undefined }));
              }
            }}
            placeholder='e.g., "pages"'
            maxLength={UNIT_MAX_LENGTH}
          />
          {errors.unit && (
            <span className={styles.fieldError}>{errors.unit}</span>
          )}
        </div>

        {/* Title Field (Optional) */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="counter-task-title">
            Title
          </label>
          <input
            id="counter-task-title"
            type="text"
            className={`${styles.input} ${errors.title ? styles.inputError : ''}`}
            value={title}
            onChange={(e) => {
              setTitle(e.target.value);
              if (errors.title) {
                setErrors((prev) => ({ ...prev, title: undefined }));
              }
            }}
            placeholder="Auto-generated if blank"
            maxLength={TITLE_MAX_LENGTH}
          />
          {errors.title && (
            <span className={styles.fieldError}>{errors.title}</span>
          )}
        </div>

        {/* Description Field (Optional) */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="counter-task-description">
            Description
          </label>
          <textarea
            id="counter-task-description"
            className={`${styles.input} ${styles.textarea} ${errors.description ? styles.inputError : ''}`}
            value={description}
            onChange={(e) => {
              setDescription(e.target.value);
              if (errors.description) {
                setErrors((prev) => ({ ...prev, description: undefined }));
              }
            }}
            placeholder="Enter task description (optional)"
            maxLength={DESCRIPTION_MAX_LENGTH}
          />
          {errors.description && (
            <span className={styles.fieldError}>{errors.description}</span>
          )}
        </div>

        {/* Submit Button */}
        <button type="submit" className={styles.submitButton}>
          Create Counter Task
        </button>
      </form>

      {/* Success Message */}
      {showSuccess && (
        <div className={styles.successMessage}>Counter task created!</div>
      )}

      {/* Error Message */}
      {submitError && (
        <div className={styles.fieldError}>{submitError}</div>
      )}

      {/* Counter Task List */}
      <div className={styles.taskListSection}>
        <h4 className={styles.taskListTitle}>Created Counter Tasks</h4>

        {counterTasks.length === 0 ? (
          <p className={styles.emptyState}>No counter tasks created yet.</p>
        ) : (
          <div className={styles.taskList}>
            {counterTasks.map((task: Task) => (
              <div key={task.id} className={styles.taskCard}>
                <div className={styles.taskCardHeader}>
                  <span className={styles.taskTitle}>{task.title}</span>
                  <span className={styles.taskBadge}>COUNTING</span>
                </div>
                <p className={styles.taskDescription}>
                  {task.action} {task.maxCount} {task.unit}
                </p>
                {task.description && (
                  <p className={styles.taskDescription}>{task.description}</p>
                )}
                <p className={styles.taskDate}>
                  Created: {formatDate(task.createdAt)}
                </p>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
