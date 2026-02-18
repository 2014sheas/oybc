import { useState, useCallback } from 'react';
import { TaskType, type Task } from '@oybc/shared';
import { createTask } from '../db';
import { useTasks } from '../hooks';
import styles from './TaskCreationPlayground.module.css';

/** Maximum character lengths matching shared validation schemas */
const TITLE_MAX_LENGTH = 200;
const DESCRIPTION_MAX_LENGTH = 1000;

/** Mock user ID for Playground testing */
const PLAYGROUND_USER_ID = 'playground-user-1';

/** Duration in ms before success message auto-dismisses */
const SUCCESS_DISMISS_MS = 3000;

/**
 * Validation error state for the task creation form
 */
interface FormErrors {
  title?: string;
  description?: string;
}

/**
 * Validates the task creation form fields.
 *
 * @param title - The task title
 * @param description - The optional task description
 * @returns Object containing any validation errors
 */
function validateForm(title: string, description: string): FormErrors {
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
 * TaskCreationPlayground - Playground feature for creating NORMAL tasks
 *
 * Provides a form to create tasks stored in the real Dexie database,
 * a reactive task list that updates automatically, and success feedback.
 * Only supports NORMAL task type.
 */
export function TaskCreationPlayground(): React.ReactElement {
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [errors, setErrors] = useState<FormErrors>({});
  const [showSuccess, setShowSuccess] = useState(false);

  // Reactive task list - auto-updates when database changes
  const tasks = useTasks(PLAYGROUND_USER_ID);

  /**
   * Handles form submission to create a new NORMAL task.
   * Validates inputs, creates the task in Dexie, clears the form,
   * and shows a success message that auto-dismisses.
   */
  const handleSubmit = useCallback(async (e: React.FormEvent) => {
    e.preventDefault();

    // Validate
    const validationErrors = validateForm(title, description);
    setErrors(validationErrors);

    if (Object.keys(validationErrors).length > 0) {
      return;
    }

    // Create task in Dexie
    await createTask(PLAYGROUND_USER_ID, {
      title: title.trim(),
      description: description.trim() || undefined,
      type: TaskType.NORMAL,
    });

    // Clear form
    setTitle('');
    setDescription('');
    setErrors({});

    // Show success message
    setShowSuccess(true);
    setTimeout(() => {
      setShowSuccess(false);
    }, SUCCESS_DISMISS_MS);
  }, [title, description]);

  return (
    <div className={styles.container}>
      {/* Task Creation Form */}
      <form className={styles.form} onSubmit={handleSubmit}>
        {/* Title Field */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="task-title">
            Title<span className={styles.required}>*</span>
          </label>
          <input
            id="task-title"
            type="text"
            className={`${styles.input} ${errors.title ? styles.inputError : ''}`}
            value={title}
            onChange={(e) => {
              setTitle(e.target.value);
              if (errors.title) {
                setErrors((prev) => ({ ...prev, title: undefined }));
              }
            }}
            placeholder="Enter task title"
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
          <label className={styles.label} htmlFor="task-description">
            Description
          </label>
          <textarea
            id="task-description"
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

        {/* Submit Button */}
        <button type="submit" className={styles.submitButton}>
          Create Task
        </button>
      </form>

      {/* Success Message */}
      {showSuccess && (
        <div className={styles.successMessage}>Task created!</div>
      )}

      {/* Task List */}
      <div className={styles.taskListSection}>
        <h4 className={styles.taskListTitle}>Created Tasks</h4>

        {tasks.length === 0 ? (
          <p className={styles.emptyState}>No tasks created yet.</p>
        ) : (
          <div className={styles.taskList}>
            {tasks.map((task: Task) => (
              <div key={task.id} className={styles.taskCard}>
                <div className={styles.taskCardHeader}>
                  <span className={styles.taskTitle}>{task.title}</span>
                  <span className={styles.taskBadge}>NORMAL</span>
                </div>
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
