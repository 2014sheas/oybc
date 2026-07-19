import { useCallback, useEffect } from 'react';
import { useCreateFormState, type PendingTaskPayload } from '../../pages/createPage/useCreateFormState';
import { CreateNewTaskForm } from '../../pages/createPage/CreateNewTaskForm';
import { type LinkedCounterInput } from './CountingTemplatePicker';
import { createTask } from '../../db/operations/tasks';
import { generateUUID, currentTimestamp } from '../../db/utils';
import { TaskType, type Task, type Timeframe } from '@oybc/shared';
import styles from './NewTaskSheet.module.css';

export interface NewTaskSheetProps {
  isOpen: boolean;
  onClose: () => void;
  userId: string;
  /** Fired when a NORMAL/COUNTING/PROGRESS task is created. The wizard
   *  should auto-add the new id to its `selectedTaskIds` set; the Tasks
   *  tab just dismisses the sheet (the live-query refreshes the list). */
  onTaskCreated: (task: Task) => void;
  /**
   * Bug #85 — Deferred-persist supplemental callback. When provided,
   * `deferPersist` is implicitly enabled. Called with the full pending
   * payload alongside `onTaskCreated` so the wizard can store it for
   * the board-save transaction. Absent for standalone Tasks-tab usage
   * (immediate persist, no wizard context).
   */
  onPendingCreated?: (payload: PendingTaskPayload) => void;
  /** Fired when a compound (formerly composite) task is created. The
   *  wizard typically reloads the library so the compound shows up under
   *  filters. Under the unified compound model composites are Tasks, so
   *  the callback signature uses Task. */
  onCompositeCreated: (task: Task) => void;
  /** Optional override for the form's submit button label. The wizard
   *  context wants "Create & Select" (the new task is auto-added to the
   *  pool); the Tasks-tab context wants "Add to library". */
  submitLabel?: string;
  /** Phase 6.Y — Timeboxed Tasks. When the sheet is mounted from the
   *  board wizard, the wizard passes its `currentTimeframe` + dates so
   *  every task created here inherits the board's window. Standalone
   *  Tasks-tab usage omits these and resulting tasks are indefinite. */
  defaultTimeframe?: Timeframe;
  defaultStartDate?: string;
  defaultEndDate?: string;
  /**
   * Bug #85 — When `true`, the form builds the task fully in memory
   * and fires `onTaskCreated` + `onPendingCreated` without any DB
   * write. Defaults to `false` (immediate persist). The wizard sets
   * this to `true` via the Tasks step; standalone Tasks-tab usage
   * keeps it `false`.
   */
  deferPersist?: boolean;
}

/**
 * NewTaskSheet — Modal wrapper around `CreateNewTaskForm` for use
 * inside the board-creation wizard's Tasks step.
 *
 * The actual form lives in `NewTaskSheetBody`, which is only mounted
 * while the sheet is open. That guarantees `useCreateFormState`
 * unmounts on close and the form resets cleanly the next time the
 * sheet opens — without it, the hook persists across opens and a
 * half-typed title from a previous attempt would leak through.
 *
 * Click on the backdrop or press Escape to dismiss.
 */
export function NewTaskSheet({
  isOpen,
  onClose,
  userId,
  onTaskCreated,
  onPendingCreated,
  onCompositeCreated,
  submitLabel,
  defaultTimeframe,
  defaultStartDate,
  defaultEndDate,
  deferPersist = false,
}: NewTaskSheetProps): React.ReactElement | null {
  useEffect(() => {
    if (!isOpen) return;
    function onKey(e: KeyboardEvent): void {
      if (e.key === 'Escape') onClose();
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [isOpen, onClose]);

  if (!isOpen) return null;

  return (
    <NewTaskSheetBody
      onClose={onClose}
      userId={userId}
      onTaskCreated={onTaskCreated}
      onPendingCreated={onPendingCreated}
      onCompositeCreated={onCompositeCreated}
      submitLabel={submitLabel}
      defaultTimeframe={defaultTimeframe}
      defaultStartDate={defaultStartDate}
      defaultEndDate={defaultEndDate}
      deferPersist={deferPersist}
    />
  );
}

/**
 * Inner body that owns `useCreateFormState`. Rendered only while the
 * sheet is open so the hook tears down on close — see parent docstring.
 */
function NewTaskSheetBody({
  onClose,
  userId,
  onTaskCreated,
  onPendingCreated,
  onCompositeCreated,
  submitLabel,
  defaultTimeframe,
  defaultStartDate,
  defaultEndDate,
  deferPersist = false,
}: Omit<NewTaskSheetProps, 'isOpen'>): React.ReactElement {
  const form = useCreateFormState({
    userId,
    onTaskCreated: (task) => {
      onTaskCreated(task);
      onClose();
    },
    onPendingCreated,
    defaultTimeframe,
    defaultStartDate,
    defaultEndDate,
    deferPersist,
  });

  /**
   * R1 counters refresh — auto-link. `CreateNewTaskForm` calls this instead
   * of `form.handleSubmit` when a counting-task submit's (verb, noun) pair
   * exactly matches an existing counter and the user hasn't opted out via
   * `CounterLinkHint`'s "Don't link" pill (linking is ON by default; the
   * manual "Link to existing counter" mode this docstring used to describe
   * was retired — see `CountingTemplatePicker`). Creates a new COUNTING
   * task with `sharedCounterId` + `baseline` set, then notifies the parent
   * and closes the sheet. Respects the same deferred-persist path as the
   * regular COUNTING create so wizard usage stays atomic.
   */
  const handleCreateLinked = useCallback(
    async (input: LinkedCounterInput): Promise<void> => {
      if (!userId) return;
      try {
        let newTask: Task;
        if (deferPersist) {
          // Build in-memory for the wizard — written inside the board-save txn.
          const now = currentTimestamp();
          newTask = {
            id: generateUUID(),
            userId,
            title: input.title,
            type: TaskType.COUNTING,
            action: input.source.action ?? '',
            unit: input.source.unit ?? '',
            maxCount: input.maxCount,
            currentCount: 0,
            sharedCounterId: input.source.id,
            baseline: input.baseline,
            isCompleted: false,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            timeframe: defaultTimeframe,
            startDate: defaultStartDate,
            endDate: defaultEndDate,
            // Wizard-born — hidden from the task library until the board goes active.
            createdInWizard: true,
          };
          onPendingCreated?.({ task: newTask, childTasks: [], childLinks: [] });
        } else {
          // Immediate-persist path (Tasks-tab standalone quick-add).
          newTask = await createTask(userId, {
            title: input.title,
            type: TaskType.COUNTING,
            action: input.source.action ?? '',
            unit: input.source.unit ?? '',
            maxCount: input.maxCount,
            sharedCounterId: input.source.id,
            baseline: input.baseline,
            timeframe: defaultTimeframe,
            startDate: defaultStartDate,
            endDate: defaultEndDate,
          });
        }
        onTaskCreated(newTask);
        onClose();
      } catch (err) {
        // Surface to the console; the form has no dedicated error banner for
        // the link path. A future iteration can thread an error state.
        console.error('[NewTaskSheet] handleCreateLinked failed:', err);
      }
    },
    [
      userId,
      deferPersist,
      onTaskCreated,
      onPendingCreated,
      onClose,
      defaultTimeframe,
      defaultStartDate,
      defaultEndDate,
    ],
  );

  return (
    <div
      className={styles.backdrop}
      onClick={onClose}
    >
      {/* The dialog role + label live on the sheet itself, not the
          backdrop. The backdrop is a click-to-dismiss overlay; screen
          readers should announce the label when focus enters the
          dialog content, which is the inner sheet div. */}
      <div
        className={styles.sheet}
        role="dialog"
        aria-modal="true"
        aria-labelledby="new-task-sheet-title"
        onClick={(e) => e.stopPropagation()}
      >
        <div className={styles.header}>
          <h3 id="new-task-sheet-title" className={styles.title}>New task</h3>
          <button
            type="button"
            className={styles.closeButton}
            onClick={onClose}
            aria-label="Close"
          >
            ✕
          </button>
        </div>
        <div className={styles.body}>
          <CreateNewTaskForm
            form={form}
            userId={userId}
            onCompositeCreated={(ct) => {
              onCompositeCreated(ct);
              onClose();
            }}
            submitLabel={submitLabel ?? 'Create & Select'}
            onCreateLinked={handleCreateLinked}
          />
        </div>
      </div>
    </div>
  );
}
