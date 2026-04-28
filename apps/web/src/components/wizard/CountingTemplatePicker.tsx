import { useRef, useState } from 'react';
import { TaskType, type Task } from '@oybc/shared';
import { useTaskLibrary } from '../../pages/createPage/useTaskLibrary';
import styles from './CountingTemplatePicker.module.css';

export interface CountingTemplatePickerProps {
  /** Authenticated user id — used to load the task library. */
  userId: string | undefined;
  /** The task currently used as a template, or null if none. */
  selectedTemplate: Task | null;
  /** Called when the user picks a source counting task. */
  onSelect: (task: Task) => void;
  /** Called when the user clears the current template selection. */
  onClear: () => void;
}

/**
 * CountingTemplatePicker — Compact "derive from existing" affordance for
 * the counting-type variant of CreateNewTaskForm / CreateNewTaskFormView.
 *
 * When no template is selected: renders a dashed button labelled
 * "Use existing task as template...". Clicking it opens an inline
 * dropdown listing all non-deleted counting tasks in the user's library.
 *
 * When a template is selected: renders a compact banner showing
 * "Template: <title>" with a clear (×) button. The parent form's action
 * and unit fields will have been pre-filled; maxCount is left empty for
 * the user to fill in. Clearing the banner resets the autofill.
 *
 * Loads the library via `useTaskLibrary(userId)` directly — same pattern
 * used by CompositeTaskWizard.
 */
export function CountingTemplatePicker({
  userId,
  selectedTemplate,
  onSelect,
  onClear,
}: CountingTemplatePickerProps): React.ReactElement {
  const [open, setOpen] = useState(false);
  const buttonRef = useRef<HTMLButtonElement>(null);

  const library = useTaskLibrary(userId);
  const countingTasks = library.allTasks.filter(
    (t) => t.type === TaskType.COUNTING && !t.isDeleted,
  );

  function handleSelect(task: Task): void {
    onSelect(task);
    setOpen(false);
  }

  if (selectedTemplate !== null) {
    return (
      <div className={styles.selectedBanner}>
        <span className={styles.selectedLabel}>Template:</span>
        <span className={styles.selectedTitle}>{selectedTemplate.title}</span>
        <button
          type="button"
          className={styles.clearButton}
          onClick={onClear}
          aria-label="Clear template"
        >
          ✕
        </button>
      </div>
    );
  }

  return (
    <div className={styles.dropdownWrapper}>
      <button
        ref={buttonRef}
        type="button"
        className={styles.affordance}
        onClick={() => setOpen((prev) => !prev)}
        aria-expanded={open}
        aria-haspopup="listbox"
      >
        Use existing counting task as template...
      </button>
      {open && (
        <div className={styles.dropdown} role="listbox" aria-label="Counting task templates">
          {countingTasks.length === 0 ? (
            <p className={styles.dropdownEmpty}>No counting tasks in your library yet.</p>
          ) : (
            countingTasks.map((task) => (
              <button
                key={task.id}
                type="button"
                className={styles.dropdownItem}
                role="option"
                aria-selected={false}
                onClick={() => handleSelect(task)}
              >
                {task.title}
                {task.action && task.unit ? (
                  <span className={styles.dropdownMeta}>
                    {task.action} · {task.unit}
                  </span>
                ) : null}
              </button>
            ))
          )}
        </div>
      )}
    </div>
  );
}
