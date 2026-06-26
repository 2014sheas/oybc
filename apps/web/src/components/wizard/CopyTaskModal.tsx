import { useEffect, useState } from 'react';
import {
  AchievementTrigger,
  TaskType,
  type Task,
} from '@oybc/shared';
import { copyTask, copyCompound, type CopyTaskOverrides } from '../../db/operations/tasks';
import styles from './CopyTaskModal.module.css';

interface CopyTaskModalProps {
  /** Source task being copied. */
  source: Task;
  /** Authenticated user — passed to copyTask/copyCompound. */
  userId: string;
  /** Called after a successful save with the new Task. The parent
   *  should mark `source.id` as "copied this session" + auto-add
   *  the new task to selection. */
  onCopied: (newTask: Task) => void;
  /** Called when the user cancels or escapes. */
  onCancel: () => void;
}

/**
 * Copy modal for the `From a board` grid's `⎘ Add a copy of this task…`
 * action. Fields are pre-filled from the source and editable per type:
 *
 * - Normal:      title only
 * - Counting:    title + action + maxCount + unit
 * - Compound:    title only (children references stay shared)
 * - Achievement: title + trigger + requiredCount (when template mode).
 *                Reference target stays the source's; re-target is a
 *                follow-up — the user can edit the new task from the
 *                Tasks tab after Save.
 *
 * Routes through the existing `copyTask` / `copyCompound` helpers so
 * Zod validation + sync-queue writes happen identically to a brand-new
 * task. Errors surface inline rather than aborting the wizard step.
 */
export function CopyTaskModal({
  source,
  userId,
  onCopied,
  onCancel,
}: CopyTaskModalProps): React.ReactElement {
  const [title, setTitle] = useState(source.title);
  const [action, setAction] = useState(source.action ?? '');
  const [unit, setUnit] = useState(source.unit ?? '');
  const [maxCountInput, setMaxCountInput] = useState(
    source.maxCount != null ? String(source.maxCount) : '',
  );
  const [trigger, setTrigger] = useState<AchievementTrigger>(
    source.achievementTrigger ?? AchievementTrigger.GREENLOG,
  );
  const [requiredCountInput, setRequiredCountInput] = useState(
    source.requiredCount != null ? String(source.requiredCount) : '',
  );
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onCancel();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onCancel]);

  const isCounting = source.type === TaskType.COUNTING;
  const isCompound = source.type === TaskType.COMPOUND;
  const isAchievement = source.type === TaskType.ACHIEVEMENT;
  const isTemplateMode =
    isAchievement && source.referencedTemplateId !== undefined;

  async function handleSave(): Promise<void> {
    setError(null);
    const trimmedTitle = title.trim();
    if (trimmedTitle.length === 0) {
      setError('Title is required');
      return;
    }

    setSaving(true);
    try {
      let newTask: Task;
      if (isCompound) {
        newTask = await copyCompound(userId, source, { title: trimmedTitle });
      } else {
        const overrides: CopyTaskOverrides = { title: trimmedTitle };
        if (isCounting) {
          const parsedMax = parseInt(maxCountInput.trim(), 10);
          if (!Number.isFinite(parsedMax) || parsedMax <= 0) {
            throw new Error('Goal must be a positive integer');
          }
          overrides.action = action.trim();
          overrides.unit = unit.trim();
          overrides.maxCount = parsedMax;
        }
        if (isAchievement) {
          overrides.achievementTrigger = trigger;
          if (isTemplateMode) {
            const parsedRequired = parseInt(requiredCountInput.trim(), 10);
            if (!Number.isFinite(parsedRequired) || parsedRequired <= 0) {
              throw new Error('Required count must be a positive integer');
            }
            overrides.requiredCount = parsedRequired;
          }
        }
        newTask = await copyTask(userId, source, overrides);
      }
      onCopied(newTask);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Copy task"
      className={styles.backdrop}
      onClick={onCancel}
    >
      <div
        className={styles.dialog}
        onClick={(e) => e.stopPropagation()}
      >
        <h3 className={styles.title}>Add a copy of this task</h3>
        <div className={styles.sourceHint}>
          Source: <strong>{source.title}</strong>
        </div>

        <Field label="Title">
          <input
            autoFocus
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            className={styles.fieldInput}
          />
        </Field>

        {isCounting && (
          <>
            <Field label="Action">
              <input
                type="text"
                value={action}
                onChange={(e) => setAction(e.target.value)}
                className={styles.fieldInput}
              />
            </Field>
            <Field label="Goal">
              <input
                type="number"
                inputMode="numeric"
                min={1}
                value={maxCountInput}
                onChange={(e) => setMaxCountInput(e.target.value)}
                className={styles.fieldInput}
              />
            </Field>
            <Field label="Unit">
              <input
                type="text"
                value={unit}
                onChange={(e) => setUnit(e.target.value)}
                className={styles.fieldInput}
              />
            </Field>
          </>
        )}

        {isAchievement && (
          <>
            <Field label="Trigger">
              <select
                value={trigger}
                onChange={(e) => setTrigger(e.target.value as AchievementTrigger)}
                className={styles.fieldInput}
              >
                <option value={AchievementTrigger.GREENLOG}>Greenlog</option>
                <option value={AchievementTrigger.BINGO}>Bingo</option>
              </select>
            </Field>
            {isTemplateMode && (
              <Field label="Required count">
                <input
                  type="number"
                  inputMode="numeric"
                  min={1}
                  value={requiredCountInput}
                  onChange={(e) => setRequiredCountInput(e.target.value)}
                  className={styles.fieldInput}
                />
              </Field>
            )}
            <div className={styles.hint}>
              The copy watches the same target as the source. To re-target, edit the
              new task from the Tasks tab after Save.
            </div>
          </>
        )}

        {isCompound && (
          <div className={styles.hint}>
            The copy reuses the source's subtasks. Completing the original subtasks
            still completes them on the copy and vice versa (shared children).
          </div>
        )}

        {error && (
          <div className={styles.error}>{error}</div>
        )}

        <div className={styles.actions}>
          <button
            type="button"
            onClick={onCancel}
            disabled={saving}
            className={styles.cancelButton}
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={() => void handleSave()}
            disabled={saving}
            className={styles.saveButton}
          >
            {saving ? 'Saving…' : 'Save copy'}
          </button>
        </div>
      </div>
    </div>
  );
}

function Field({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}): React.ReactElement {
  return (
    <label className={styles.field}>
      <div className={styles.fieldLabel}>{label}</div>
      {children}
    </label>
  );
}
