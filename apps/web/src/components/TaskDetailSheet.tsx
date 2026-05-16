import { useEffect, useState } from 'react';
import { db } from '../db/database';
import { TaskDetailContent } from '../pages/tasks/TaskDetailContent';
import styles from './TaskDetailSheet.module.css';

interface TaskDetailSheetProps {
  /**
   * Task ID to display. When null, the sheet renders nothing (closed state).
   */
  taskId: string | null;
  /** Called when the user dismisses the sheet (Done button or backdrop tap). */
  onClose: () => void;
  /**
   * Called when a chip or child row inside the detail content wants to
   * navigate to another task. The sheet swaps its internal taskId state
   * ("replace" semantics — same sheet, different task).
   * Optional: if omitted, navigation chips inside the content are still
   * rendered but will no-op on click.
   */
  onOpenTask?: (taskId: string) => void;
}

/**
 * TaskDetailSheet — presents `TaskDetailContent` as a fixed-overlay sheet.
 *
 * Mount at a page root and drive it with `taskId` state. When `taskId` is
 * set the sheet slides in over the current content; when null it renders
 * nothing.
 *
 * **Navigation semantics (v1 — "replace")**: when the content fires
 * `onOpenTask`, the sheet swaps its internal task ID in place. There is no
 * breadcrumb trail. If `onOpenTask` is provided by the caller, that callback
 * runs instead (use this when the parent wants to manage the navigation
 * stack itself). TODO: add a "← back to <prev task>" affordance in a
 * follow-up once the replace semantics prove insufficient.
 *
 * **404 handling**: a one-shot `db.tasks.get()` confirms the row exists at
 * mount. If the task was deleted while the sheet was open, the sheet shows
 * "No longer exists" and offers a close button rather than silently dangling.
 */
export function TaskDetailSheet({
  taskId,
  onClose,
  onOpenTask,
}: TaskDetailSheetProps): React.ReactElement | null {
  // Internal task ID state — initialized from prop, reset when prop changes.
  // This enables the "replace" navigation semantic inside the sheet.
  const [innerTaskId, setInnerTaskId] = useState<string | null>(taskId);

  // Sync prop → inner state whenever the caller swaps the outer task.
  useEffect(() => {
    setInnerTaskId(taskId);
  }, [taskId]);

  if (taskId === null) return null;

  return (
    <SheetBody
      taskId={innerTaskId}
      onClose={onClose}
      onOpenTask={(id) => {
        if (onOpenTask) {
          onOpenTask(id);
        } else {
          // Replace semantics: swap inner task ID.
          setInnerTaskId(id);
        }
      }}
    />
  );
}

// ─── Internal sheet body (loaded once taskId is non-null) ─────────────────────

interface SheetBodyProps {
  taskId: string | null;
  onClose: () => void;
  onOpenTask: (taskId: string) => void;
}

function SheetBody({ taskId, onClose, onOpenTask }: SheetBodyProps): React.ReactElement | null {
  const [resolved, setResolved] = useState<'pending' | 'present' | 'missing'>('pending');
  const [task, setTask] = useState<import('@oybc/shared').Task | null>(null);

  useEffect(() => {
    if (!taskId) {
      setResolved('missing');
      return;
    }
    setResolved('pending');
    let cancelled = false;
    void (async () => {
      const row = await db.tasks.get(taskId);
      if (cancelled) return;
      if (row === undefined || row.isDeleted) {
        setResolved('missing');
      } else {
        setTask(row);
        setResolved('present');
      }
    })();
    return () => { cancelled = true; };
  }, [taskId]);

  // Keep task state fresh when the DB row changes while the sheet is open
  // (e.g. after a successful edit). useLiveQuery would be cleaner here but
  // requires using it at the top level; the one-shot pattern plus a
  // post-edit `onChanged` callback achieves the same result without adding
  // a live subscription in a conditionally-rendered component.
  const handleChanged = async () => {
    if (!taskId) return;
    const row = await db.tasks.get(taskId);
    if (!row || row.isDeleted) {
      onClose();
    } else {
      setTask(row);
    }
  };

  return (
    <div
      className={styles.backdrop}
      onClick={onClose}
      role="presentation"
    >
      <div
        className={styles.sheetPanel}
        role="dialog"
        aria-modal="true"
        aria-label="Task detail"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Top-right Done button */}
        <div className={styles.sheetToolbar}>
          <button
            type="button"
            className={styles.doneButton}
            onClick={onClose}
          >
            Done
          </button>
        </div>

        {resolved === 'pending' && (
          <p className={styles.statusMessage}>Loading…</p>
        )}

        {resolved === 'missing' && (
          <div className={styles.missingState}>
            <p className={styles.statusMessage}>This task no longer exists.</p>
            <button
              type="button"
              className={styles.doneButton}
              onClick={onClose}
            >
              Close
            </button>
          </div>
        )}

        {resolved === 'present' && task && (
          <TaskDetailContent
            task={task}
            onChanged={handleChanged}
            onClose={onClose}
            onOpenTask={onOpenTask}
          />
        )}
      </div>
    </div>
  );
}
