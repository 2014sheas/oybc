import { useEffect } from 'react';
import { useCreateFormState } from '../../pages/createPage/useCreateFormState';
import { CreateNewTaskForm } from '../../pages/createPage/CreateNewTaskForm';
import type { Task } from '@oybc/shared';
import styles from './NewTaskSheet.module.css';

export interface NewTaskSheetProps {
  isOpen: boolean;
  onClose: () => void;
  userId: string;
  /** Fired when a NORMAL/COUNTING/PROGRESS task is created. The wizard
   *  should auto-add the new id to its `selectedTaskIds` set. */
  onTaskCreated: (task: Task) => void;
  /** Fired when a compound (formerly composite) task is created. The
   *  wizard typically reloads the library so the compound shows up under
   *  filters. Under the unified compound model composites are Tasks, so
   *  the callback signature uses Task. */
  onCompositeCreated: (task: Task) => void;
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
  onCompositeCreated,
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
      onCompositeCreated={onCompositeCreated}
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
  onCompositeCreated,
}: Omit<NewTaskSheetProps, 'isOpen'>): React.ReactElement {
  const form = useCreateFormState({
    userId,
    onTaskCreated: (task) => {
      onTaskCreated(task);
      onClose();
    },
  });

  return (
    <div
      className={styles.backdrop}
      role="dialog"
      aria-modal="true"
      aria-label="Create a new task"
      onClick={onClose}
    >
      <div className={styles.sheet} onClick={(e) => e.stopPropagation()}>
        <div className={styles.header}>
          <h3 className={styles.title}>New task</h3>
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
            submitLabel="Create & Select"
          />
        </div>
      </div>
    </div>
  );
}
