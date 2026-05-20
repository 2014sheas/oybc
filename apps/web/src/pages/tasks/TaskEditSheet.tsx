import { useState } from 'react';
import { AchievementTrigger, TaskType, type Task } from '@oybc/shared';
import styles from './TaskDetailContent.module.css';

export interface TaskEditSheetProps {
  task: Task;
  onSubmit: (patch: Partial<Task>) => Promise<void>;
  onCancel: () => void;
}

/**
 * TaskEditSheet — modal sheet for editing a task's editable fields.
 *
 * Extracted from `TaskDetailContent` so the Tasks-tab row can present
 * the same edit affordance via the trailing ✎ button without
 * navigating to the detail page first. Behavior is identical: the
 * caller supplies the persistence callback so this sheet stays
 * agnostic about whether the result is reflected via live-query
 * reactivity or an explicit reload.
 *
 * Shares CSS module with `TaskDetailContent` to avoid styling drift —
 * both surfaces render the same sheet shape and field controls.
 */
export function TaskEditSheet({
  task,
  onSubmit,
  onCancel,
}: TaskEditSheetProps): React.ReactElement {
  const [title, setTitle] = useState(task.title);
  const [description, setDescription] = useState(task.description ?? '');
  const [action, setAction] = useState(task.action ?? '');
  const [unit, setUnit] = useState(task.unit ?? '');
  const [maxCountStr, setMaxCountStr] = useState(
    task.maxCount !== undefined ? String(task.maxCount) : '',
  );
  const [trigger, setTrigger] = useState<AchievementTrigger>(
    task.achievementTrigger ?? AchievementTrigger.GREENLOG,
  );
  const [requiredCountStr, setRequiredCountStr] = useState(
    task.requiredCount !== undefined ? String(task.requiredCount) : '',
  );
  const [submitting, setSubmitting] = useState(false);
  const [validationError, setValidationError] = useState<string | null>(null);

  const parsePositiveInt = (raw: string): number | null | 'empty' => {
    const trimmed = raw.trim();
    if (trimmed === '') return 'empty';
    const parsed = parseInt(trimmed, 10);
    if (!Number.isInteger(parsed) || parsed <= 0) return null;
    return parsed;
  };

  const handleSubmit = async () => {
    setValidationError(null);
    const patch: Partial<Task> = {
      title: title.trim(),
      description: description.trim() || undefined,
    };
    if (task.type === TaskType.COUNTING) {
      patch.action = action.trim();
      patch.unit = unit.trim();
      const result = parsePositiveInt(maxCountStr);
      if (result === null) {
        setValidationError('Max Count must be a whole number greater than 0.');
        return;
      }
      if (result !== 'empty') {
        patch.maxCount = result;
      }
    }
    if (task.type === TaskType.ACHIEVEMENT) {
      patch.achievementTrigger = trigger;
      if (task.referencedTemplateId) {
        const result = parsePositiveInt(requiredCountStr);
        if (result === null) {
          setValidationError('Required count must be a whole number greater than 0.');
          return;
        }
        if (result !== 'empty') {
          patch.requiredCount = result;
        }
      }
    }
    setSubmitting(true);
    await onSubmit(patch);
    setSubmitting(false);
  };

  return (
    <div className={styles.sheetBackdrop} onClick={onCancel}>
      <div
        className={styles.sheet}
        role="dialog"
        aria-label="Edit task"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className={styles.sheetHeading}>Edit task</h2>

        <label className={styles.field}>
          <span className={styles.fieldLabel}>Title</span>
          <input
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            className={styles.fieldInput}
          />
        </label>

        <label className={styles.field}>
          <span className={styles.fieldLabel}>Description</span>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className={styles.fieldTextarea}
            rows={3}
          />
        </label>

        {task.type === TaskType.COUNTING && (
          <>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Action</span>
              <input
                type="text"
                value={action}
                onChange={(e) => setAction(e.target.value)}
                className={styles.fieldInput}
              />
            </label>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Max Count</span>
              <input
                type="number"
                min={1}
                step={1}
                value={maxCountStr}
                onChange={(e) => setMaxCountStr(e.target.value)}
                className={styles.fieldInput}
              />
            </label>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Unit</span>
              <input
                type="text"
                value={unit}
                onChange={(e) => setUnit(e.target.value)}
                className={styles.fieldInput}
              />
            </label>
          </>
        )}

        {task.type === TaskType.ACHIEVEMENT && (
          <>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Trigger</span>
              <select
                value={trigger}
                onChange={(e) => setTrigger(e.target.value as AchievementTrigger)}
                className={styles.fieldInput}
              >
                <option value={AchievementTrigger.GREENLOG}>Greenlog</option>
                <option value={AchievementTrigger.BINGO}>Bingo</option>
              </select>
            </label>
            {task.referencedTemplateId && (
              <label className={styles.field}>
                <span className={styles.fieldLabel}>Required count</span>
                <input
                  type="number"
                  min={1}
                  step={1}
                  value={requiredCountStr}
                  onChange={(e) => setRequiredCountStr(e.target.value)}
                  className={styles.fieldInput}
                />
              </label>
            )}
          </>
        )}

        {task.type === TaskType.COMPOUND && (
          <p className={styles.compoundHint}>
            Compound subtasks are edited from the board-creation wizard. The
            title and description can still be changed here.
          </p>
        )}

        {validationError !== null && (
          <p className={styles.error} role="alert">
            {validationError}
          </p>
        )}

        <div className={styles.sheetActions}>
          <button
            type="button"
            className={styles.cancelButton}
            onClick={onCancel}
            disabled={submitting}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.saveButton}
            onClick={handleSubmit}
            disabled={submitting || !title.trim()}
          >
            {submitting ? 'Saving…' : 'Save changes'}
          </button>
        </div>
      </div>
    </div>
  );
}
