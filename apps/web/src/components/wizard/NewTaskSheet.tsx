import { useEffect } from 'react';
import { useCreateFormState } from '../../pages/createPage/useCreateFormState';
import { CreateNewTaskForm } from '../../pages/createPage/CreateNewTaskForm';
import type { Task, CompositeTask } from '@oybc/shared';
import styles from './NewTaskSheet.module.css';

export interface NewTaskSheetProps {
  isOpen: boolean;
  onClose: () => void;
  userId: string;
  /** Fired when a NORMAL/COUNTING/PROGRESS task is created. The wizard
   *  should auto-add the new id to its `selectedTaskIds` set. */
  onTaskCreated: (task: Task) => void;
  /** Fired when a composite task is created. The wizard typically
   *  reloads the library so the composite shows up under filters; it
   *  is NOT auto-selected because composites can't be boarded directly. */
  onCompositeCreated: (ct: CompositeTask) => void;
}

/**
 * NewTaskSheet — Modal wrapper around `CreateNewTaskForm` for use
 * inside the board-creation wizard's Tasks step.
 *
 * Owns its own `useCreateFormState` instance so the form state resets
 * cleanly each time the sheet opens. On successful submission the
 * sheet calls the parent's `onTaskCreated` (or `onCompositeCreated`)
 * and dismisses itself; the parent is responsible for auto-selecting
 * the new task in the wizard's selection set.
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
  const form = useCreateFormState({
    userId,
    onTaskCreated: (task) => {
      onTaskCreated(task);
      onClose();
    },
  });

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
