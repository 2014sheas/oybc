import { useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { Link } from 'react-router-dom';
import {
  AchievementTrigger,
  TaskType,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { db } from '../../db/database';
import {
  computeTaskDeletionImpact,
  deleteTaskWithCascade,
  fetchCompoundParentsForTask,
  updateTask,
  type TaskDeletionImpact,
} from '../../db/operations/tasks';
import { fetchTemplatesReferencingTask } from '../../db/operations/recurringBoardTemplates';
import { TypeBadge } from '../../components/TypeBadge';
import { formatRelativeTime } from '../../utils/relativeTime';
import styles from './TaskDetailContent.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface TaskDetailContentProps {
  task: Task;
  /**
   * Called after a successful edit or deletion intent. The route consumer
   * passes a no-op; the sheet consumer can use it to trigger list refreshes.
   */
  onChanged: () => void;
  /**
   * Called for the back / close affordance. The route consumer passes
   * `() => navigate('/tasks')`. The sheet consumer passes `() => setOpen(false)`.
   * When omitted, no back affordance is rendered in the header (the route
   * shows the existing Link header; the sheet renders its own Done button).
   */
  onClose?: () => void;
  /**
   * Called when a chip or child row inside the content wants to navigate
   * to another task's detail. Route consumer: `(id) => navigate('/tasks/'+id)`.
   * Sheet consumer: swaps internal taskId state (replace semantics).
   */
  onOpenTask?: (taskId: string) => void;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function typeLabel(task: Task): string {
  if (task.type !== TaskType.COMPOUND) return task.type;
  return task.isOrdered === true ? 'progress' : 'composite';
}

function formatDate(iso: string): string {
  try {
    const d = new Date(iso);
    return d.toLocaleDateString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    });
  } catch {
    return iso;
  }
}

// ─── Sub-components ────────────────────────────────────────────────────────────

function StatusPill({ task }: { task: Task }): React.ReactElement {
  if (task.isCompleted) {
    return <span className={`${styles.statusPill} ${styles.statusCompleted}`}>Completed</span>;
  }
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

// ─── Edit sheet ───────────────────────────────────────────────────────────────

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
  const [validationError, setValidationError] = useState<string | null>(null);

  const parsePositiveInt = (raw: string): number | null | 'empty' => {
    const trimmed = raw.trim();
    if (trimmed === '') return 'empty';
    const parsed = parseInt(trimmed, 10);
    if (!Number.isInteger(parsed) || parsed <= 0) return null;
    return parsed;
  };

  const handleSubmit = async () => {
    setValidationError(null);
    const patch: Partial<Task> = {
      title: title.trim(),
      description: description.trim() || undefined,
    };
    if (task.type === TaskType.COUNTING) {
      patch.action = action.trim();
      patch.unit = unit.trim();
      const result = parsePositiveInt(maxCountStr);
      if (result === null) {
        setValidationError('Max Count must be a whole number greater than 0.');
        return;
      }
      if (result !== 'empty') {
        patch.maxCount = result;
      }
    }
    if (task.type === TaskType.ACHIEVEMENT) {
      patch.achievementTrigger = trigger;
      if (task.referencedTemplateId) {
        const result = parsePositiveInt(requiredCountStr);
        if (result === null) {
          setValidationError('Required count must be a whole number greater than 0.');
          return;
        }
        if (result !== 'empty') {
          patch.requiredCount = result;
        }
      }
    }
    setSubmitting(true);
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
              <span className={styles.fieldLabel}>Max Count</span>
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

        {validationError !== null && (
          <p className={styles.error} role="alert">
            {validationError}
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

// ─── Confirm delete dialog ────────────────────────────────────────────────────

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
          "{task.title || '(untitled task)'}" will be removed from your library.
          This can't be undone.
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
              {impact.parentLinkCount === 1 ? '' : 's'} (
              {impact.parentLinkCount === 1 ? 'it stays' : 'they stay'} in your
              library).
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

// ─── Main exported component ──────────────────────────────────────────────────

/**
 * TaskDetailContent — shareable task detail body.
 *
 * Renders all sections:
 *   - Title + TypeBadge + StatusPill + description
 *   - Type-specific facts (counting / achievement)
 *   - Subtask of (parent compound back-refs)         NEW
 *   - Subtasks (compound children summary)           NEW
 *   - Part of recurring template                     NEW
 *   - Usage (board placements)
 *   - Timestamps (restyled with relative time)       NEW
 *   - Edit / Delete actions
 *
 * Chrome (back button, routing) is the caller's responsibility.
 */
export function TaskDetailContent({
  task,
  onChanged,
  onClose,
  onOpenTask,
}: TaskDetailContentProps): React.ReactElement {
  const taskId = task.id;

  // ── Placement / board data ─────────────────────────────────────────────

  const placements = useLiveQuery(
    async () => db.boardTasks.where('taskId').equals(taskId).toArray(),
    [taskId],
  ) as BoardTask[] | undefined;

  const placementBoardIds = useMemo(() => {
    if (!placements) return [] as string[];
    return Array.from(new Set(placements.map((bt) => bt.boardId)));
  }, [placements]);

  const placementBoardIdsKey = placementBoardIds.join(',');
  const affectedBoards = useLiveQuery(
    async () =>
      placementBoardIds.length === 0
        ? []
        : await db.boards
            .where('id')
            .anyOf(placementBoardIds)
            .filter((b) => !b.isDeleted)
            .toArray(),
    [placementBoardIdsKey],
  ) as Board[] | undefined;

  // ── Parent compounds (subtask-of back-ref) ─────────────────────────────

  const parentCompounds = useLiveQuery(
    () => fetchCompoundParentsForTask(taskId),
    [taskId],
  ) as Task[] | undefined;

  // ── Child tasks (compound children summary) ────────────────────────────

  const compoundChildren = useLiveQuery(
    async () =>
      task.type === TaskType.COMPOUND
        ? db.compoundChildren
            .filter((c: CompoundChild) => !c.isDeleted && c.compoundTaskId === taskId)
            .toArray()
        : [],
    [taskId, task.type],
  ) as CompoundChild[] | undefined;

  // Sort children by childIndex
  const sortedChildren = useMemo(() => {
    if (!compoundChildren) return [];
    return [...compoundChildren].sort((a, b) => a.childIndex - b.childIndex);
  }, [compoundChildren]);

  // Build a task map for child title/type lookups
  const childTaskIds = useMemo(
    () => sortedChildren.map((c) => c.childTaskId),
    [sortedChildren],
  );
  const childTaskIdsKey = childTaskIds.join(',');
  const childTasks = useLiveQuery(
    async () =>
      childTaskIds.length === 0
        ? []
        : db.tasks
            .where('id')
            .anyOf(childTaskIds)
            .filter((t) => !t.isDeleted)
            .toArray(),
    [childTaskIdsKey],
  ) as Task[] | undefined;

  const childTaskMap = useMemo(() => {
    const m: Record<string, Task> = {};
    for (const t of childTasks ?? []) m[t.id] = t;
    return m;
  }, [childTasks]);

  // ── Recurring template back-refs ───────────────────────────────────────

  const referencingTemplates = useLiveQuery(
    () => fetchTemplatesReferencingTask(taskId),
    [taskId],
  );

  // ── Edit / delete UI state ─────────────────────────────────────────────

  const [isEditing, setIsEditing] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleteImpact, setDeleteImpact] = useState<TaskDeletionImpact | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handleDeleteClick = async () => {
    setError(null);
    try {
      const impact = await computeTaskDeletionImpact(taskId);
      setDeleteImpact(impact);
      setConfirmDelete(true);
    } catch (e) {
      setError(`Failed to compute delete impact: ${(e as Error).message}`);
    }
  };

  const handleConfirmDelete = async () => {
    setError(null);
    try {
      await deleteTaskWithCascade(taskId);
      onChanged();
      onClose?.();
    } catch (e) {
      setError(`Failed to delete task: ${(e as Error).message}`);
      setConfirmDelete(false);
    }
  };

  // Relative times
  const lastCompletedRel = formatRelativeTime(task.completedAt);
  const updatedRel = formatRelativeTime(task.updatedAt);

  return (
    <div className={styles.shell}>
      {/* No back affordance here — the caller (route page or sheet wrapper)
          owns the header chrome since their navigation semantics differ:
          route → "‹ Tasks" link to /tasks; sheet → "Done" button. */}

      {/* Title + badges + description */}
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

      {/* Type-specific facts */}
      <TypeSpecificFacts task={task} />

      {/* Subtask of: parent compound back-refs */}
      {parentCompounds && parentCompounds.length > 0 && (
        <section className={styles.section}>
          <h2 className={styles.sectionHeading}>Subtask of</h2>
          <div className={styles.chipRow}>
            {parentCompounds.map((parent) => (
              <button
                key={parent.id}
                type="button"
                className={styles.taskChip}
                onClick={() => onOpenTask?.(parent.id)}
                aria-label={`Open parent task: ${parent.title || '(untitled task)'}`}
              >
                <TypeBadge type={typeLabel(parent)} />
                {parent.title || '(untitled task)'}
              </button>
            ))}
          </div>
        </section>
      )}

      {/* Subtasks: compound children summary */}
      {task.type === TaskType.COMPOUND && sortedChildren.length >= 0 && (
        <section className={styles.section}>
          <h2 className={styles.sectionHeading}>
            Subtasks{sortedChildren.length > 0 ? ` (${sortedChildren.length})` : ''}
          </h2>
          {sortedChildren.length === 0 ? (
            <p className={styles.metaLine}>No subtasks yet.</p>
          ) : (
            <div className={styles.subtaskList}>
              {sortedChildren.map((link) => {
                const child = childTaskMap[link.childTaskId];
                if (!child) return null;
                return (
                  <button
                    key={link.id}
                    type="button"
                    className={styles.subtaskRow}
                    onClick={() => onOpenTask?.(child.id)}
                    aria-label={`Open subtask: ${child.title || '(untitled task)'}`}
                  >
                    <span className={child.isCompleted ? styles.subtaskCheck : styles.subtaskCheckEmpty}>
                      {child.isCompleted ? '✓' : '○'}
                    </span>
                    <TypeBadge type={typeLabel(child)} />
                    <span className={`${styles.subtaskTitle} ${child.isCompleted ? styles.subtaskTitleDone : ''}`}>
                      {child.title || '(untitled task)'}
                    </span>
                  </button>
                );
              })}
            </div>
          )}
          <p className={styles.subtaskHint}>
            Compound subtasks are edited from the board-creation wizard.
          </p>
        </section>
      )}

      {/* Part of recurring template */}
      {referencingTemplates && referencingTemplates.length > 0 && (
        <section className={styles.section}>
          <h2 className={styles.sectionHeading}>Part of recurring template</h2>
          <div className={styles.chipRow}>
            {referencingTemplates.map((tmpl) => (
              <Link
                key={tmpl.id}
                to="/profile/recurring-templates"
                className={styles.templateChip}
                aria-label={`Part of template: ${tmpl.name}`}
              >
                Part of: {tmpl.name}
              </Link>
            ))}
          </div>
        </section>
      )}

      {/* Usage: board placements */}
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

      {/* Timestamps — restyled with relative time */}
      <section className={styles.section}>
        <h2 className={styles.sectionHeading}>Timestamps</h2>
        <div className={styles.timestampGrid}>
          {task.completedAt && lastCompletedRel && (
            <div className={styles.timestampRow}>
              <span className={styles.timestampLabel}>Last completed</span>
              <span className={`${styles.timestampValue} ${styles.timestampLead}`}>
                {lastCompletedRel}
              </span>
            </div>
          )}
          <div className={styles.timestampRow}>
            <span className={styles.timestampLabel}>Created</span>
            <span className={styles.timestampValue}>{formatDate(task.createdAt)}</span>
          </div>
          <div className={styles.timestampRow}>
            <span className={styles.timestampLabel}>Updated</span>
            <span className={styles.timestampValue}>
              {formatDate(task.updatedAt)}
              {updatedRel && (
                <span className={styles.timestampRelative}>({updatedRel})</span>
              )}
            </span>
          </div>
        </div>
      </section>

      {error && <p className={styles.error}>{error}</p>}

      {/* Actions */}
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

      {/* Edit sheet */}
      {isEditing && (
        <EditSheet
          task={task}
          onSubmit={async (patch) => {
            try {
              await updateTask(taskId, patch);
              onChanged();
              setIsEditing(false);
            } catch (e) {
              setError(`Failed to save: ${(e as Error).message}`);
            }
          }}
          onCancel={() => setIsEditing(false)}
        />
      )}

      {/* Confirm delete dialog */}
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
