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
  updateTaskAndCascade,
  type TaskDeletionImpact,
} from '../../db/operations/tasks';
import { fetchTemplatesReferencingTask } from '../../db/operations/recurringBoardTemplates';
import { TypeBadge } from '../../components/TypeBadge';
import { formatRelativeTime } from '../../utils/relativeTime';
import { TaskEditSheet } from './TaskEditSheet';
import { TaskConfirmDeleteDialog } from './TaskConfirmDeleteDialog';
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

function CountingSourceCaption({ sharedCounterId }: { sharedCounterId: string }): React.ReactElement {
  // Phase 2 — Shared Counters: single-row lookup for the source task title.
  // Rendered only when sharedCounterId is present, so the hook always fires.
  //
  // useLiveQuery returns `undefined` as the initial (loading) value regardless
  // of what the query eventually resolves to. `db.tasks.get()` resolves to
  // `undefined` when the row doesn't exist — so both "loading" and "not found"
  // would be indistinguishable if we relied on `undefined` alone.
  //
  // Fix: pass `null` as the initial value so the three states are distinct:
  //   undefined  → loading (initial value not yet overwritten by the query)
  //   null       → not found (query resolved to undefined → we map to null)
  //   Task       → loaded successfully
  const rawResult = useLiveQuery(
    () => db.tasks.get(sharedCounterId),
    [sharedCounterId],
  );
  // Map query result: undefined (DB miss) → null (not-found sentinel).
  // Until the first query result arrives rawResult is the initial `undefined`.
  const isLoading = rawResult === undefined;
  const sourceTask = (rawResult as Task | undefined) ?? null;
  // Also treat soft-deleted rows as not-found.
  const found = sourceTask !== null && !sourceTask.isDeleted;

  return (
    <p className={styles.linkedCounterCaption}>
      Linked to{' '}
      {isLoading
        ? <em>loading…</em>
        : found
          ? <strong>{(sourceTask as Task).title}</strong>
          : <em>source task (deleted or not found)</em>
      }
    </p>
  );
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
        {/* Phase 2 — Linked counter indicator. Detail-sheet only (no list/cell badge). */}
        {task.sharedCounterId != null && (
          <CountingSourceCaption sharedCounterId={task.sharedCounterId} />
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
        <TaskEditSheet
          task={task}
          onSubmit={async (patch) => {
            try {
              await updateTaskAndCascade(taskId, patch);
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
        <TaskConfirmDeleteDialog
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
