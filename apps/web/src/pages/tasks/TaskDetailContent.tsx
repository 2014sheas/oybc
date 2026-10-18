import { useState } from 'react';
import type { Task } from '@oybc/shared';
import { CompoundEditValidationError, saveTaskEdit } from '../../db/operations';
import { computeTaskDeletionImpact, deleteTaskWithCascade, type TaskDeletionImpact } from '../../db/operations/tasks';
import { useTaskDetail } from '../../hooks/useTaskDetail';
import { TaskEditSheet } from './TaskEditSheet';
import { TaskConfirmDeleteDialog } from './TaskConfirmDeleteDialog';
import { TaskDetailHero, type DetailChrome } from './taskDetail/TaskDetailHero';
import { TaskDetailSections } from './taskDetail/TaskDetailSections';
import type { DetailSegment } from './taskDetail/taskDetailModel';
import styles from './taskDetail/TaskDetail.module.css';

export type { DetailChrome } from './taskDetail/TaskDetailHero';

export interface TaskDetailContentProps {
  task: Task;
  /** After a successful edit (the sheet refreshes its task row). */
  onChanged: () => void;
  /** Route: back link. Sheet: Done pill + the return pill after an in-sheet swap. */
  chrome: DetailChrome;
  /** After the task is deleted (the route leaves to /tasks, the sheet closes). */
  onDeleted: () => void;
  onOpenTask: (taskId: string) => void;
  onOpenBoard: (boardId: string) => void;
  onOpenCounter: (counterId: string) => void;
  /** Controlled segment (the sheet keeps it across task swaps); omitted = local state. */
  segment?: DetailSegment;
  onSegment?: (segment: DetailSegment) => void;
}

/**
 * TaskDetailContent — one page, two presentations (route and "Open in library"
 * sheet): the type-coloured hero with its live control, then the segmented
 * All · Boards · Links · Activity body. Data comes from `useTaskDetail`; chrome
 * (back / Done / return pill) is the caller's.
 *
 * @returns The page body.
 */
export function TaskDetailContent({
  task, onChanged, chrome, onDeleted, onOpenTask, onOpenBoard, onOpenCounter, segment, onSegment,
}: TaskDetailContentProps): React.ReactElement {
  const data = useTaskDetail(task);
  const [localSegment, setLocalSegment] = useState<DetailSegment>('all');
  const [isEditing, setIsEditing] = useState(false);
  const [deleteImpact, setDeleteImpact] = useState<TaskDeletionImpact | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handleDelete = async (): Promise<void> => {
    setError(null);
    try {
      setDeleteImpact(await computeTaskDeletionImpact(task.id));
    } catch (e) {
      setError(`Failed to compute delete impact: ${(e as Error).message}`);
    }
  };

  const confirmDelete = async (): Promise<void> => {
    setError(null);
    try {
      await deleteTaskWithCascade(task.id);
      setDeleteImpact(null);
      onChanged();
      onDeleted();
    } catch (e) {
      setError(`Failed to delete task: ${(e as Error).message}`);
      setDeleteImpact(null);
    }
  };

  return (
    <div className={styles.shell}>
      <TaskDetailHero
        task={task} data={data} chrome={chrome} onEdit={() => setIsEditing(true)} onDelete={() => void handleDelete()}
        onOpenTask={onOpenTask} onOpenBoard={onOpenBoard} onOpenCounter={onOpenCounter}
      />
      <TaskDetailSections
        task={task} data={data} segment={segment ?? localSegment} onSegment={onSegment ?? setLocalSegment}
        onOpenTask={onOpenTask} onOpenBoard={onOpenBoard} onOpenCounter={onOpenCounter}
      />
      {error && <p className={styles.error}>{error}</p>}
      {isEditing && (
        <TaskEditSheet
          task={task}
          onSubmit={async (patch) => {
            try {
              await saveTaskEdit(task.id, patch);
              onChanged();
              setIsEditing(false);
            } catch (e) {
              // Structure validation is shown inline by the sheet.
              if (e instanceof CompoundEditValidationError) throw e;
              setError(`Failed to save: ${(e as Error).message}`);
            }
          }}
          onCancel={() => setIsEditing(false)}
        />
      )}
      {deleteImpact && (
        <TaskConfirmDeleteDialog task={task} impact={deleteImpact} onConfirm={confirmDelete} onCancel={() => setDeleteImpact(null)} />
      )}
    </div>
  );
}
