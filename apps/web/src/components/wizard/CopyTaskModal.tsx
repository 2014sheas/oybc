import { useEffect, useState } from 'react';
import {
  AchievementTrigger,
  TaskType,
  type Task,
} from '@oybc/shared';
import { copyTask, copyCompound, type CopyTaskOverrides } from '../../db/operations/tasks';

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
      onClick={onCancel}
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 1100,
        background: 'rgba(0,0,0,0.5)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: 'var(--color-bg-elevated, #1c1c1e)',
          color: 'inherit',
          border: '1px solid rgba(255,255,255,0.1)',
          borderRadius: 12,
          padding: 20,
          minWidth: 340,
          maxWidth: 440,
          boxShadow: '0 12px 40px rgba(0,0,0,0.5)',
        }}
      >
        <h3 style={{ margin: '0 0 4px', fontSize: 17 }}>Add a copy of this task</h3>
        <div style={{ marginBottom: 14, fontSize: 12, opacity: 0.55 }}>
          Source: <strong>{source.title}</strong>
        </div>

        <Field label="Title">
          <input
            autoFocus
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            style={fieldInputStyle}
          />
        </Field>

        {isCounting && (
          <>
            <Field label="Action">
              <input
                type="text"
                value={action}
                onChange={(e) => setAction(e.target.value)}
                style={fieldInputStyle}
              />
            </Field>
            <Field label="Goal">
              <input
                type="number"
                inputMode="numeric"
                min={1}
                value={maxCountInput}
                onChange={(e) => setMaxCountInput(e.target.value)}
                style={fieldInputStyle}
              />
            </Field>
            <Field label="Unit">
              <input
                type="text"
                value={unit}
                onChange={(e) => setUnit(e.target.value)}
                style={fieldInputStyle}
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
                style={fieldInputStyle}
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
                  style={fieldInputStyle}
                />
              </Field>
            )}
            <div style={{ marginTop: 8, fontSize: 11, opacity: 0.55 }}>
              The copy watches the same target as the source. To re-target, edit the
              new task from the Tasks tab after Save.
            </div>
          </>
        )}

        {isCompound && (
          <div style={{ marginTop: 8, fontSize: 11, opacity: 0.55 }}>
            The copy reuses the source's subtasks. Completing the original subtasks
            still completes them on the copy and vice versa (shared children).
          </div>
        )}

        {error && (
          <div style={{ marginTop: 12, fontSize: 13, color: '#ff6b6b' }}>{error}</div>
        )}

        <div
          style={{
            marginTop: 18,
            display: 'flex',
            justifyContent: 'flex-end',
            gap: 8,
          }}
        >
          <button
            type="button"
            onClick={onCancel}
            disabled={saving}
            style={cancelButtonStyle}
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={() => void handleSave()}
            disabled={saving}
            style={primaryButtonStyle}
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
    <label style={{ display: 'block', marginTop: 10 }}>
      <div style={{ fontSize: 12, marginBottom: 4, opacity: 0.7 }}>{label}</div>
      {children}
    </label>
  );
}

const fieldInputStyle: React.CSSProperties = {
  width: '100%',
  padding: '8px 10px',
  borderRadius: 6,
  border: '1px solid rgba(255,255,255,0.15)',
  background: 'rgba(255,255,255,0.04)',
  color: 'inherit',
  font: 'inherit',
  boxSizing: 'border-box',
};

const cancelButtonStyle: React.CSSProperties = {
  padding: '8px 14px',
  borderRadius: 6,
  background: 'transparent',
  border: '1px solid rgba(255,255,255,0.2)',
  color: 'inherit',
  cursor: 'pointer',
  font: 'inherit',
};

const primaryButtonStyle: React.CSSProperties = {
  padding: '8px 14px',
  borderRadius: 6,
  background: '#0a84ff',
  border: 0,
  color: '#fff',
  cursor: 'pointer',
  font: 'inherit',
  fontWeight: 600,
};
