import { useEffect, useRef, useState } from 'react';
import type { Task } from '@oybc/shared';
import { useCreateFormState } from '../../pages/createPage/useCreateFormState';
import { CreateNewTaskForm } from '../../pages/createPage/CreateNewTaskForm';
import styles from './CreateHubQuickAdd.module.css';

export interface CreateHubQuickAddProps {
  /** Authenticated user id — threaded through to `CreateNewTaskForm`
   *  which owns the DB write. */
  userId: string;
}

/**
 * CreateHubQuickAdd — Inline task-creation surface on the Create Hub.
 * Wraps the existing `CreateNewTaskForm` to preserve every validation
 * rule and per-type field behaviour from the legacy Create tab; new
 * tasks land in the user's library only. Composites are fully
 * supported because `CreateNewTaskForm` delegates to
 * `CompositeTaskForm` when the composite type is picked.
 *
 * This is the power-user path from the original hybrid-model design:
 * users who want to stockpile tasks without building a board can do
 * so without opening the wizard.
 */
export function CreateHubQuickAdd({ userId }: CreateHubQuickAddProps): React.ReactElement {
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  // Tracks the active dismiss timer so back-to-back creates and
  // unmounts don't leak handles or fire `setSuccessMessage(null)` on
  // an unmounted component. A bare `setTimeout` was the original
  // implementation — replaced after a Copilot review flagged the leak.
  const dismissTimerRef = useRef<number | null>(null);

  function showSuccess(message: string): void {
    setSuccessMessage(message);
    if (dismissTimerRef.current !== null) {
      window.clearTimeout(dismissTimerRef.current);
    }
    dismissTimerRef.current = window.setTimeout(() => {
      setSuccessMessage(null);
      dismissTimerRef.current = null;
    }, 3000);
  }

  useEffect(() => {
    return () => {
      if (dismissTimerRef.current !== null) {
        window.clearTimeout(dismissTimerRef.current);
        dismissTimerRef.current = null;
      }
    };
  }, []);

  function onTaskCreated(task: Task): void {
    showSuccess(`Added "${task.title}" to your library.`);
  }

  function onCompositeCreated(task: Task): void {
    showSuccess(`Added composite "${task.title}" to your library.`);
  }

  const form = useCreateFormState({ userId, onTaskCreated });

  return (
    <section className={styles.section} aria-label="Quick-add task">
      <h3 className={styles.heading}>Quick-add task</h3>
      <p className={styles.hint}>
        Add a task straight to your library — you can put it on a board later.
      </p>
      {successMessage !== null && (
        <div className={styles.successBanner} role="status">
          {successMessage}
        </div>
      )}
      <div className={styles.formWrapper}>
        <CreateNewTaskForm
          form={form}
          userId={userId}
          onCompositeCreated={onCompositeCreated}
          submitLabel="Add to library"
        />
      </div>
    </section>
  );
}
