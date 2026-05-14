import { useEffect, useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { Link, useNavigate, useParams } from 'react-router-dom';
import {
  AchievementTrigger,
  TaskType,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../db/database';
import {
  computeTaskDeletionImpact,
  deleteTaskWithCascade,
  updateTask,
  type TaskDeletionImpact,
} from '../db/operations/tasks';
import { TypeBadge } from '../components/TypeBadge';
import styles from './TaskDetailPage.module.css';

/**
 * TaskDetailPage — per-task surface with stats, edit sheet, and
 * cascade delete. Lives at `/tasks/:id`.
 *
 * V1 scope: type / status / placement stats / timestamps / inline edit
 * of title + description + scalar type-specific fields (counting:
 * action/unit/maxCount; achievement: trigger/requiredCount). Compound-
 * child editing remains a wizard concern.
 */
export function TaskDetailPage(): React.ReactElement {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const task = useLiveQuery(
    async () => (id ? db.tasks.get(id) : undefined),
    [id],
  );

  const placements = useLiveQuery(
    async () =>
      id ? await db.boardTasks.where('taskId').equals(id).toArray() : [],
    [id],
  ) as BoardTask[] | undefined;

  const affectedBoardIds = useMemo(() => {
    if (!placements) return [] as string[];
    return Array.from(new Set(placements.map((bt) => bt.boardId)));
  }, [placements]);

  const affectedBoardIdsKey = affectedBoardIds.join(',');
  const affectedBoards = useLiveQuery(
    async () =>
      affectedBoardIds.length === 0
        ? []
        : await db.boards.where('id').anyOf(affectedBoardIds).toArray(),
    [affectedBoardIdsKey],
  ) as Board[] | undefined;

  const [isEditing, setIsEditing] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleteImpact, setDeleteImpact] = useState<TaskDeletionImpact | null>(null);
  const [error, setError] = useState<string | null>(null);

  // 404 — task missing OR soft-deleted. Bounce back to the list so the
  // URL doesn't get stuck on a dead detail page (e.g., another device
  // deleted this task while we had it open).
  useEffect(() => {
    if (task === undefined) return; // still loading
    if (task === null || task.isDeleted) {
      navigate('/tasks', { replace: true });
    }
  }, [task, navigate]);

  if (!id) return <Navigate404 />;
  if (task === undefined) return <Loading />;
  if (task === null || task.isDeleted) return <Loading />;

  const handleDeleteClick = async () => {
    setError(null);
    try {
      const impact = await computeTaskDeletionImpact(id);
      setDeleteImpact(impact);
      setConfirmDelete(true);
    } catch (e) {
      setError(`Failed to compute delete impact: ${(e as Error).message}`);
    }
  };

  const handleConfirmDelete = async () => {
    setError(null);
    try {
      await deleteTaskWithCascade(id);
      navigate('/tasks', { replace: true });
    } catch (e) {
      setError(`Failed to delete task: ${(e as Error).message}`);
      setConfirmDelete(false);
    }
  };

  return (
    <div className={styles.shell}>
      <header className={styles.header}>
        <Link to="/tasks" className={styles.back}>
          ‹ Tasks
        </Link>
      </header>

      <section className={styles.titleSection}>
        <h1 className={styles.title}>{task.title || '(untitled task)'}</h1>
        <div className={styles.badges}>
          <TypeBadge type={typeLabel(task)} />
          <StatusPill task={task} />
        </div>
        {task.description && (
          <p className={styles.description}>{task.description}</p>
        )}
      </section>

      <TypeSpecificFacts task={task} />

      <section className={styles.section}>
        <h2 className={styles.sectionHeading}>Usage</h2>
        <p className={styles.metaLine}>
          Total completions: {task.totalCompletions ?? 0}
        </p>
        {placements && placements.length > 0 && affectedBoards ? (
          <ul className={styles.boardList}>
            {affectedBoards.map((b) => (
              <li key={b.id}>
                <Link to={`/boards/${b.id}`} className={styles.boardLink}>
                  {b.name}
                </Link>{' '}
                <span className={styles.boardStatusTag}>{b.status}</span>
              </li>
            ))}
          </ul>
        ) : (
          <p className={styles.metaLine}>
            Not placed on any board yet.
          </p>
        )}
      </section>

      <section className={styles.section}>
        <h2 className={styles.sectionHeading}>Timestamps</h2>
        <p className={styles.metaLine}>Created: {formatDate(task.createdAt)}</p>
        <p className={styles.metaLine}>Updated: {formatDate(task.updatedAt)}</p>
        {task.completedAt && (
          <p className={styles.metaLine}>
            Completed: {formatDate(task.completedAt)}
          </p>
        )}
      </section>

      {error && <p className={styles.error}>{error}</p>}

      <footer className={styles.actions}>
        <button
          type="button"
          className={styles.editButton}
          onClick={() => setIsEditing(true)}
        >
          Edit
        </button>
        <button
          type="button"
          className={styles.deleteButton}
          onClick={handleDeleteClick}
        >
          Delete
        </button>
      </footer>

      {isEditing && (
        <EditSheet
          task={task}
          onSubmit={async (patch) => {
            try {
              await updateTask(id, patch);
              setIsEditing(false);
            } catch (e) {
              setError(`Failed to save: ${(e as Error).message}`);
            }
          }}
          onCancel={() => setIsEditing(false)}
        />
      )}

      {confirmDelete && deleteImpact && (
        <ConfirmDeleteDialog
          task={task}
          impact={deleteImpact}
          onConfirm={handleConfirmDelete}
          onCancel={() => {
            setConfirmDelete(false);
            setDeleteImpact(null);
          }}
        />
      )}
    </div>
  );
}

function typeLabel(task: Task): string {
  if (task.type !== TaskType.COMPOUND) return task.type;
  return task.isOrdered === true ? 'progress' : 'composite';
}

function StatusPill({ task }: { task: Task }): React.ReactElement {
  if (task.isCompleted) {
    return <span className={`${styles.statusPill} ${styles.statusCompleted}`}>Completed</span>;
  }
  // In-progress detection at the detail page is best-effort: counting
  // tasks expose `currentCount` directly; compound progress requires the
  // children table which we don't fetch here for simplicity. The list
  // view's `isInProgress` covers compound semantics for filter purposes.
  if (task.type === TaskType.COUNTING && (task.currentCount ?? 0) > 0) {
    return <span className={`${styles.statusPill} ${styles.statusInProgress}`}>In progress</span>;
  }
  return <span className={`${styles.statusPill} ${styles.statusNeverStarted}`}>Never started</span>;
}

function TypeSpecificFacts({ task }: { task: Task }): React.ReactElement | null {
  if (task.type === TaskType.COUNTING) {
    const current = task.currentCount ?? 0;
    const max = task.maxCount ?? 0;
    const pct = max > 0 ? Math.min(100, Math.round((current / max) * 100)) : 0;
    return (
      <section className={styles.section}>
        <h2 className={styles.sectionHeading}>Counting</h2>
        <p className={styles.metaLine}>
          {task.action} · {current} / {max} {task.unit}
        </p>
        {max > 0 && (
          <div className={styles.progressBar} aria-label={`Progress ${pct}%`}>
            <div className={styles.progressFill} style={{ width: `${pct}%` }} />
          </div>
        )}
      </section>
    );
  }
  if (task.type === TaskType.ACHIEVEMENT) {
    const trigger = task.achievementTrigger ?? AchievementTrigger.GREENLOG;
    return (
      <section className={styles.section}>
        <h2 className={styles.sectionHeading}>Achievement</h2>
        <p className={styles.metaLine}>
          Trigger: {trigger === AchievementTrigger.BINGO ? 'Bingo' : 'Greenlog'}
        </p>
        {task.referencedBoardId && (
          <p className={styles.metaLine}>
            Watches board:{' '}
            <Link to={`/boards/${task.referencedBoardId}`} className={styles.boardLink}>
              View
            </Link>
          </p>
        )}
        {task.referencedTemplateId && (
          <p className={styles.metaLine}>
            Watches template ID: {task.referencedTemplateId}
            {task.requiredCount !== undefined && ` · ${task.requiredCount} required`}
          </p>
        )}
      </section>
    );
  }
  return null;
}

interface EditSheetProps {
  task: Task;
  onSubmit: (patch: Partial<Task>) => Promise<void>;
  onCancel: () => void;
}

function EditSheet({ task, onSubmit, onCancel }: EditSheetProps): React.ReactElement {
  const [title, setTitle] = useState(task.title);
  const [description, setDescription] = useState(task.description ?? '');
  const [action, setAction] = useState(task.action ?? '');
  const [unit, setUnit] = useState(task.unit ?? '');
  const [maxCountStr, setMaxCountStr] = useState(
    task.maxCount !== undefined ? String(task.maxCount) : '',
  );
  const [trigger, setTrigger] = useState<AchievementTrigger>(
    task.achievementTrigger ?? AchievementTrigger.GREENLOG,
  );
  const [requiredCountStr, setRequiredCountStr] = useState(
    task.requiredCount !== undefined ? String(task.requiredCount) : '',
  );
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async () => {
    setSubmitting(true);
    const patch: Partial<Task> = {
      title: title.trim(),
      description: description.trim() || undefined,
    };
    if (task.type === TaskType.COUNTING) {
      patch.action = action.trim();
      patch.unit = unit.trim();
      const parsed = parseInt(maxCountStr, 10);
      if (Number.isInteger(parsed) && parsed > 0) {
        patch.maxCount = parsed;
      }
    }
    if (task.type === TaskType.ACHIEVEMENT) {
      patch.achievementTrigger = trigger;
      if (task.referencedTemplateId) {
        const parsed = parseInt(requiredCountStr, 10);
        if (Number.isInteger(parsed) && parsed > 0) {
          patch.requiredCount = parsed;
        }
      }
    }
    await onSubmit(patch);
    setSubmitting(false);
  };

  return (
    <div className={styles.sheetBackdrop} onClick={onCancel}>
      <div
        className={styles.sheet}
        role="dialog"
        aria-label="Edit task"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className={styles.sheetHeading}>Edit task</h2>

        <label className={styles.field}>
          <span className={styles.fieldLabel}>Title</span>
          <input
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            className={styles.fieldInput}
          />
        </label>

        <label className={styles.field}>
          <span className={styles.fieldLabel}>Description</span>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className={styles.fieldTextarea}
            rows={3}
          />
        </label>

        {task.type === TaskType.COUNTING && (
          <>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Action</span>
              <input
                type="text"
                value={action}
                onChange={(e) => setAction(e.target.value)}
                className={styles.fieldInput}
              />
            </label>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Max count</span>
              <input
                type="number"
                min={1}
                step={1}
                value={maxCountStr}
                onChange={(e) => setMaxCountStr(e.target.value)}
                className={styles.fieldInput}
              />
            </label>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Unit</span>
              <input
                type="text"
                value={unit}
                onChange={(e) => setUnit(e.target.value)}
                className={styles.fieldInput}
              />
            </label>
          </>
        )}

        {task.type === TaskType.ACHIEVEMENT && (
          <>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Trigger</span>
              <select
                value={trigger}
                onChange={(e) => setTrigger(e.target.value as AchievementTrigger)}
                className={styles.fieldInput}
              >
                <option value={AchievementTrigger.GREENLOG}>Greenlog</option>
                <option value={AchievementTrigger.BINGO}>Bingo</option>
              </select>
            </label>
            {task.referencedTemplateId && (
              <label className={styles.field}>
                <span className={styles.fieldLabel}>Required count</span>
                <input
                  type="number"
                  min={1}
                  step={1}
                  value={requiredCountStr}
                  onChange={(e) => setRequiredCountStr(e.target.value)}
                  className={styles.fieldInput}
                />
              </label>
            )}
          </>
        )}

        {task.type === TaskType.COMPOUND && (
          <p className={styles.compoundHint}>
            Compound subtasks are edited from the board-creation wizard. The
            title and description can still be changed here.
          </p>
        )}

        <div className={styles.sheetActions}>
          <button
            type="button"
            className={styles.cancelButton}
            onClick={onCancel}
            disabled={submitting}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.saveButton}
            onClick={handleSubmit}
            disabled={submitting || !title.trim()}
          >
            {submitting ? 'Saving…' : 'Save changes'}
          </button>
        </div>
      </div>
    </div>
  );
}

interface ConfirmDeleteDialogProps {
  task: Task;
  impact: TaskDeletionImpact;
  onConfirm: () => void;
  onCancel: () => void;
}

function ConfirmDeleteDialog({
  task,
  impact,
  onConfirm,
  onCancel,
}: ConfirmDeleteDialogProps): React.ReactElement {
  return (
    <div className={styles.sheetBackdrop} onClick={onCancel}>
      <div
        className={styles.sheet}
        role="alertdialog"
        aria-label="Confirm delete"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className={styles.sheetHeading}>Delete task?</h2>
        <p className={styles.confirmBody}>
          “{task.title || '(untitled task)'}” will be removed from your library.
          This can’t be undone.
        </p>
        <ul className={styles.impactList}>
          {impact.boardTaskCount > 0 && (
            <li>
              Removes from {impact.boardTaskCount} board square
              {impact.boardTaskCount === 1 ? '' : 's'} across{' '}
              {impact.affectedBoardIds.length} board
              {impact.affectedBoardIds.length === 1 ? '' : 's'}.
            </li>
          )}
          {impact.childLinkCount > 0 && (
            <li>
              Detaches from {impact.childLinkCount} compound parent
              {impact.childLinkCount === 1 ? '' : 's'} (the parent
              {impact.childLinkCount === 1 ? '' : 's'} loses this child).
            </li>
          )}
          {impact.parentLinkCount > 0 && (
            <li>
              Releases {impact.parentLinkCount} subtask
              {impact.parentLinkCount === 1 ? '' : 's'} (the subtask{' '}
              {impact.parentLinkCount === 1 ? 'Task stays' : 'Tasks stay'} in
              your library).
            </li>
          )}
          {impact.boardTaskCount === 0 &&
            impact.childLinkCount === 0 &&
            impact.parentLinkCount === 0 && <li>No other rows affected.</li>}
        </ul>
        <div className={styles.sheetActions}>
          <button
            type="button"
            className={styles.cancelButton}
            onClick={onCancel}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.deleteButton}
            onClick={onConfirm}
          >
            Delete
          </button>
        </div>
      </div>
    </div>
  );
}

function Loading(): React.ReactElement {
  return (
    <div className={styles.shell}>
      <p className={styles.loading}>Loading…</p>
    </div>
  );
}

function Navigate404(): React.ReactElement {
  return (
    <div className={styles.shell}>
      <p className={styles.loading}>Task not found.</p>
      <Link to="/tasks" className={styles.back}>‹ Tasks</Link>
    </div>
  );
}

function formatDate(iso: string): string {
  try {
    const d = new Date(iso);
    return d.toLocaleString();
  } catch {
    return iso;
  }
}
