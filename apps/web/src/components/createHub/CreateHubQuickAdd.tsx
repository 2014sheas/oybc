import { useState } from 'react';
import type { Task, CompositeTask } from '@oybc/shared';
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

  function onTaskCreated(task: Task): void {
    setSuccessMessage(`Added "${task.title}" to your library.`);
    window.setTimeout(() => setSuccessMessage(null), 3000);
  }

  function onCompositeCreated(ct: CompositeTask): void {
    setSuccessMessage(`Added composite "${ct.title}" to your library.`);
    window.setTimeout(() => setSuccessMessage(null), 3000);
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
