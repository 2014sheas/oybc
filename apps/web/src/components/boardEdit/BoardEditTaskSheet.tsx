import { useState } from 'react';
import { TaskType, generateCounterTaskTitle, type Task } from '@oybc/shared';
import type { UpdateTaskPatch } from '../../db/operations/tasks';
import { TypeBadge } from '../TypeBadge';
import styles from './BoardEditTaskSheet.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface BoardEditTaskSheetProps {
  /**
   * The global Task to edit. May be the live task plus any already-staged
   * overrides merged by the caller — so re-opening the sheet shows the user's
   * previously staged values, not the DB state.
   */
  task: Task;
  /**
   * Called when the user taps "Done". Receives a `UpdateTaskPatch` whose
   * fields can be spread into the caller's `taskOverrides` map. NO DB write
   * happens here — the caller stages the patch and commits on Save.
   *
   * @param taskId - The task being edited (same as `task.id`)
   * @param patch - Validated staged changes for this task
   */
  onDone: (taskId: string, patch: UpdateTaskPatch) => void;
  /** Dismiss without staging any changes. */
  onCancel: () => void;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** Human-readable type label for the type-indicator chips (no "Free" — Phase 2b). */
function typeLabel(type: TaskType | string): string {
  switch (type) {
    case TaskType.NORMAL:      return 'Simple';
    case TaskType.COUNTING:    return 'Counting';
    case TaskType.COMPOUND:    return 'Compound';
    case TaskType.ACHIEVEMENT: return 'Achievement';
    default:                   return String(type);
  }
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * BoardEditTaskSheet — bottom-sheet for staged edits to a global Task's fields
 * in Board Edit mode. Distinct from the Tasks-tab `TaskEditSheet` in two ways:
 *
 *   1. It does NOT write to the database on Done — it calls `onDone` with a
 *      validated `UpdateTaskPatch` that the caller stages in memory.
 *   2. It covers only the fields relevant to board display: name, and per-type
 *      Counting fields (action / goal / unit with live "Reads as…" preview).
 *      Compound shows the title + a read-only step-count note.
 *      Type is displayed but NOT changeable (immutable post-creation).
 *
 * "Editing this task changes it everywhere it's used." hint is always visible
 * so users understand the global impact before staging the change.
 *
 * @param task - The task (with any caller-applied overrides pre-merged)
 * @param onDone - Receives the staged patch; caller increments squareEditCount
 * @param onCancel - Dismiss without staging
 */
export function BoardEditTaskSheet({
  task,
  onDone,
  onCancel,
}: BoardEditTaskSheetProps): React.ReactElement {
  // ── Seed from task (which has overrides pre-merged by caller) ────────────

  const [title, setTitle] = useState(task.title ?? '');

  // Counting fields
  const [action, setAction] = useState(task.action ?? '');
  const [goalStr, setGoalStr] = useState(
    task.maxCount !== undefined ? String(task.maxCount) : '',
  );
  const [unit, setUnit] = useState(task.unit ?? '');

  // ── Validation ───────────────────────────────────────────────────────────

  const goalNum = parseFloat(goalStr);
  const goalValid = goalStr.trim() !== '' && Number.isInteger(goalNum) && goalNum > 0;

  /** Whether the Done button should be enabled. */
  const canSave: boolean = (() => {
    switch (task.type) {
      case TaskType.NORMAL:
      case TaskType.COMPOUND:
      case TaskType.ACHIEVEMENT:
        // Title required; counting-specific fields don't apply.
        return title.trim().length > 0;
      case TaskType.COUNTING:
        // Title is optional (auto-generated from action+goal+unit when blank).
        // Goal must be a positive integer; unit must be non-empty.
        return goalValid && unit.trim().length > 0;
      default:
        return title.trim().length > 0;
    }
  })();

  // ── "Reads as" preview (Counting only) ──────────────────────────────────

  const readsAs: string | null =
    task.type === TaskType.COUNTING && goalValid && unit.trim()
      ? generateCounterTaskTitle(action.trim(), goalNum, unit.trim(), title.trim() || undefined)
      : null;

  // ── Submit ───────────────────────────────────────────────────────────────

  const handleDone = () => {
    if (!canSave) return;

    const patch: UpdateTaskPatch = {};

    switch (task.type) {
      case TaskType.COUNTING: {
        // Title is optional for counting — send trimmed value (may be '' which
        // means "use auto-generated title"). If blank, preserve existing title
        // so the display doesn't flash to '' while staged.
        patch.title = title.trim() || task.title;
        patch.action = action.trim();
        patch.maxCount = Math.max(1, goalNum);
        patch.unit = unit.trim();
        break;
      }
      case TaskType.NORMAL:
      case TaskType.COMPOUND:
      case TaskType.ACHIEVEMENT:
      default: {
        patch.title = title.trim();
        break;
      }
    }

    onDone(task.id, patch);
  };

  // ── Render ───────────────────────────────────────────────────────────────

  return (
    <div className={styles.backdrop} onClick={onCancel} role="presentation">
      <div
        className={styles.sheet}
        role="dialog"
        aria-modal="true"
        aria-label="Edit task"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className={styles.sheetHeader}>
          <h2 className={styles.sheetTitle}>Edit task</h2>
          {/* Global-impact hint — always visible. */}
          <p className={styles.globalHint} role="note">
            Editing this task changes it everywhere it&rsquo;s used.
          </p>
        </div>

        {/* Type indicator (read-only) */}
        <div className={styles.typeRow}>
          <span className={styles.typeLabel}>Type</span>
          <div className={styles.typeBadgeWrap}>
            <TypeBadge type={task.type} size="small" />
            <span className={styles.typeReadOnly}>{typeLabel(task.type)}</span>
          </div>
        </div>

        {/* Task name */}
        <label className={styles.field}>
          <span className={styles.fieldLabel}>
            Task name
            {task.type === TaskType.COUNTING && (
              <span className={styles.optional}> (optional)</span>
            )}
          </span>
          <input
            type="text"
            className={styles.fieldInput}
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            autoFocus
            placeholder={
              task.type === TaskType.COUNTING
                ? 'Auto-generated from goal if blank…'
                : 'Task name…'
            }
          />
        </label>

        {/* Counting-specific fields */}
        {task.type === TaskType.COUNTING && (
          <>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Action</span>
              <input
                type="text"
                className={styles.fieldInput}
                value={action}
                onChange={(e) => setAction(e.target.value)}
                placeholder="e.g. Run, Read, Drink…"
              />
            </label>

            <div className={styles.countRow}>
              <label className={`${styles.field} ${styles.goalField}`}>
                <span className={styles.fieldLabel}>Goal</span>
                <input
                  type="number"
                  className={styles.fieldInput}
                  min={1}
                  step={1}
                  value={goalStr}
                  onChange={(e) => setGoalStr(e.target.value)}
                  placeholder="e.g. 10"
                />
              </label>
              <label className={`${styles.field} ${styles.unitField}`}>
                <span className={styles.fieldLabel}>Unit</span>
                <input
                  type="text"
                  className={styles.fieldInput}
                  value={unit}
                  onChange={(e) => setUnit(e.target.value)}
                  placeholder="km, cups, pages…"
                />
              </label>
            </div>

            {/* Live "Reads as…" preview */}
            {readsAs && (
              <p className={styles.preview} aria-live="polite">
                Reads as <strong>{readsAs}</strong>
              </p>
            )}
          </>
        )}

        {/* Compound: show read-only step info */}
        {task.type === TaskType.COMPOUND && (
          <p className={styles.compoundNote}>
            Compound subtask structure is edited from the task library — only the
            name can be changed here.
          </p>
        )}

        {/* Footer */}
        <div className={styles.footer}>
          <button
            type="button"
            className={styles.cancelBtn}
            onClick={onCancel}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.doneBtn}
            disabled={!canSave}
            onClick={handleDone}
          >
            Done
          </button>
        </div>
      </div>
    </div>
  );
}
