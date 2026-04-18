import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  TaskType,
  generateCounterTaskTitle,
  type Task,
  type TaskStep,
  type CompositeTask,
} from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { usePreferences } from '../hooks';
import { createTask, linkTaskStep } from '../db/operations/tasks';
import { FilterTabs } from '../components/FilterTabs';
import { TypeBadge } from '../components/TypeBadge';
import { PoolItem } from '../components/PoolItem';
import { CountingDerivationPanel } from '../components/CountingDerivationPanel';
import { ProgressDerivationPanel } from '../components/ProgressDerivationPanel';
import { CompositeDerivationPanel } from '../components/CompositeDerivationPanel';
import { BoardCreatorPanel } from '../components/BoardCreatorPanel';
import { useBoardPool } from './createPage/useBoardPool';
import {
  useTaskLibrary,
  filterLibraryForDisplay,
  COMPOSITE_TYPE,
  type ExistingFilter,
} from './createPage/useTaskLibrary';
import { useCreateFormState } from './createPage/useCreateFormState';
import { CreateNewTaskForm } from './createPage/CreateNewTaskForm';
import styles from './CreatePage.module.css';

// ─── Constants ────────────────────────────────────────────────────────────────

const SUCCESS_DISMISS_MS = 3000;

type Mode = 'create' | 'existing';

const MODE_TABS: { value: Mode; label: string }[] = [
  { value: 'create', label: 'Create New' },
  { value: 'existing', label: 'Existing Tasks' },
];

const EXISTING_FILTER_TABS: { value: ExistingFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: TaskType.PROGRESS, label: 'Progress' },
  { value: COMPOSITE_TYPE, label: 'Composite' },
];

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * CreatePage — Production task pool builder + board creation.
 *
 * Two-tab interface:
 * - Create New: form for Normal/Counting/Progress/Composite tasks, auto-added to pool
 * - Existing Tasks: filterable task library with derivation panels
 *
 * Board Task Pool is always visible at the bottom. When pool has enough tasks,
 * BoardCreatorPanel lets the user configure and create a board, then navigates
 * to the board play view.
 *
 * State owners:
 * - `useBoardPool`           — pool entries + add/remove/membership.
 * - `useTaskLibrary`         — user's tasks + composites + nodes + steps + lookup maps.
 * - `useCreateFormState`     — Create-New form: fields, errors, submit, reset.
 * - `useState` (inline)      — UI-only state: mode, success toast, expand, filter, in-flight derive.
 */
export function CreatePage(): React.ReactElement {
  const { user } = useAuth();
  const navigate = useNavigate();
  const userId = user?.id;

  // Gate `BoardCreatorPanel` mounting on this so its `useState` lazy
  // initialisers snapshot real preferences instead of placeholder defaults
  // returned while the live-query is still hydrating.
  const [preferences, , preferencesReady] = usePreferences();

  // ── Mode + UI-only state ────────────────────────────────────────────────
  const [mode, setMode] = useState<Mode>('create');
  const [existingFilter, setExistingFilter] = useState<ExistingFilter>('all');
  const [expandedTaskId, setExpandedTaskId] = useState<string | null>(null);
  const [partialCount, setPartialCount] = useState('');
  const [isCreating, setIsCreating] = useState(false);
  const [creationSuccess, setCreationSuccess] = useState<string | null>(null);

  // ── Pool + library ──────────────────────────────────────────────────────
  const { pool: boardPool, addToPool, removeFromPool, isInPool, clearPool } = useBoardPool();
  const library = useTaskLibrary(userId);
  const { allCompositeNodes, allTaskSteps, taskMap, compositeTaskMap } = library;
  const { filteredTasks, filteredCompositeTasks } = filterLibraryForDisplay(library, existingFilter);

  // ── Success toast ───────────────────────────────────────────────────────

  // Track the pending success-dismiss timer so a rapid sequence of success
  // messages doesn't let an earlier timer clear a newer message, and so we
  // can clean up on unmount.
  const successTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (successTimerRef.current) clearTimeout(successTimerRef.current);
    };
  }, []);

  const showSuccess = useCallback((message: string): void => {
    setCreationSuccess(message);
    if (successTimerRef.current) clearTimeout(successTimerRef.current);
    successTimerRef.current = setTimeout(() => {
      setCreationSuccess(null);
      successTimerRef.current = null;
    }, SUCCESS_DISMISS_MS);
  }, []);

  // ── Create-New form (hook) ──────────────────────────────────────────────
  const form = useCreateFormState({
    userId,
    onTaskCreated: useCallback(
      (newTask: Task) => {
        addToPool({ taskId: newTask.id, title: newTask.title, type: newTask.type });
        showSuccess(`Created & added to pool: "${newTask.title}"`);
      },
      [addToPool, showSuccess]
    ),
  });

  // ── Existing Tasks tab helpers ──────────────────────────────────────────

  function toggleExpand(id: string): void {
    setExpandedTaskId((prev) => (prev === id ? null : id));
    setPartialCount('');
  }

  function canDerive(taskType_: string): boolean {
    return taskType_ === TaskType.COUNTING || taskType_ === TaskType.PROGRESS || taskType_ === 'composite';
  }

  function handleExistingFilterChange(newFilter: ExistingFilter): void {
    setExistingFilter(newFilter);
    setPartialCount('');

    if (expandedTaskId) {
      const task = taskMap[expandedTaskId];
      const composite = compositeTaskMap[expandedTaskId];

      if (task) {
        const nowVisible = newFilter === 'all' || task.type === newFilter;
        if (!nowVisible) setExpandedTaskId(null);
      } else if (composite) {
        const nowVisible = newFilter === 'all' || newFilter === COMPOSITE_TYPE;
        if (!nowVisible) setExpandedTaskId(null);
      }
    }
  }

  async function handleCreateCountingSubtask(task: Task, count: number): Promise<void> {
    if (!userId) return;
    setIsCreating(true);
    try {
      const newTask = await createTask(userId, {
        type: TaskType.COUNTING,
        title: generateCounterTaskTitle(task.action!, count, task.unit!),
        description: `Subtask of "${task.title}"`,
        action: task.action!,
        unit: task.unit!,
        maxCount: count,
      });
      addToPool({ taskId: newTask.id, title: newTask.title, type: newTask.type });
      showSuccess(`Added to board pool: "${newTask.title}"`);
      setPartialCount('');
    } catch (err) {
      console.error('Failed to create subtask:', err);
    } finally {
      setIsCreating(false);
    }
  }

  async function handleExtractStep(step: TaskStep): Promise<void> {
    if (!userId) return;

    if (step.linkedTaskId) {
      const linkedTask = taskMap[step.linkedTaskId];
      if (linkedTask) {
        addToPool({ taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type });
        showSuccess(`Added to board pool: "${linkedTask.title}"`);
      }
      return;
    }

    setIsCreating(true);
    try {
      const isCountingStep =
        step.type === TaskType.COUNTING &&
        step.action !== undefined &&
        step.unit !== undefined &&
        step.maxCount !== undefined;

      const newTask = await createTask(userId, {
        type: isCountingStep ? TaskType.COUNTING : TaskType.NORMAL,
        title: isCountingStep
          ? generateCounterTaskTitle(step.action!, step.maxCount!, step.unit!)
          : step.title,
        description:
          step.title !==
          (isCountingStep
            ? generateCounterTaskTitle(step.action!, step.maxCount!, step.unit!)
            : step.title)
            ? step.title
            : undefined,
        action: isCountingStep ? step.action! : undefined,
        unit: isCountingStep ? step.unit! : undefined,
        maxCount: isCountingStep ? step.maxCount! : undefined,
      });

      // Link the step → new task atomically (transaction + sync queue) so
      // the linkedTaskId change is durable and replicates to other devices.
      await linkTaskStep(step.id, newTask.id);

      addToPool({ taskId: newTask.id, title: newTask.title, type: newTask.type });
      showSuccess(`Added to board pool: "${newTask.title}"`);
    } catch (err) {
      console.error('Failed to extract step:', err);
    } finally {
      setIsCreating(false);
    }
  }

  // ── Render: inline derivation panels ────────────────────────────────────

  function renderInlineTaskPanel(task: Task): React.ReactElement {
    return (
      <div className={styles.inlinePanel}>
        <div className={styles.panelAddRow}>
          <span className={styles.panelAddLabel}>{task.title}</span>
          {isInPool(task.id) ? (
            <span className={styles.inPoolBadge}>In Pool</span>
          ) : (
            <button
              type="button"
              className={styles.addButton}
              onClick={() => {
                addToPool({ taskId: task.id, title: task.title, type: task.type });
                showSuccess(`Added to board pool: "${task.title}"`);
              }}
            >
              Add to Pool
            </button>
          )}
        </div>

        {task.type === TaskType.COUNTING && (
          <>
            <div className={styles.panelDivider} />
            <span className={styles.panelSectionLabel}>Or derive a subtask:</span>
            <CountingDerivationPanel
              task={task}
              partialCount={partialCount}
              onPartialCountChange={setPartialCount}
              onCreateSubtask={handleCreateCountingSubtask}
              isCreating={isCreating}
            />
          </>
        )}
        {task.type === TaskType.PROGRESS && (
          <>
            <div className={styles.panelDivider} />
            <span className={styles.panelSectionLabel}>Or extract steps:</span>
            <ProgressDerivationPanel
              taskId={task.id}
              onExtractStep={handleExtractStep}
              onAddStepToPool={(step: TaskStep) => {
                if (step.linkedTaskId) {
                  const linkedTask = taskMap[step.linkedTaskId];
                  if (linkedTask) {
                    addToPool({ taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type });
                    showSuccess(`Added to board pool: "${linkedTask.title}"`);
                  }
                }
              }}
              isCreating={isCreating}
              isInPool={isInPool}
            />
          </>
        )}
      </div>
    );
  }

  function renderInlineCompositePanel(ct: CompositeTask): React.ReactElement {
    return (
      <div className={styles.inlinePanel}>
        <span className={styles.panelSectionLabel}>Add individual subtasks to the pool:</span>
        <CompositeDerivationPanel
          compositeTask={ct}
          allNodes={allCompositeNodes}
          taskMap={taskMap}
          compositeTaskMap={compositeTaskMap}
          onAddLeafToPool={(taskId_: string, leafTitle: string, type: string) => {
            addToPool({ taskId: taskId_, title: leafTitle, type });
            showSuccess(`Added to board pool: "${leafTitle}"`);
          }}
          isInPool={isInPool}
        />
      </div>
    );
  }

  // ── Render ──────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      <h1 className={styles.header}>Create</h1>

      {/* Success message */}
      {creationSuccess && <div className={styles.successMessage}>{creationSuccess}</div>}

      {/* Mode tabs */}
      <div className={styles.modeTabRow}>
        <FilterTabs
          tabs={MODE_TABS}
          activeTab={mode}
          onTabChange={(value) => setMode(value as Mode)}
        />
        {boardPool.length > 0 && (
          <button
            type="button"
            className={styles.poolChip}
            onClick={() => {
              document.getElementById('create-board-task-pool')?.scrollIntoView({ behavior: 'smooth' });
            }}
          >
            Pool: {boardPool.length}
          </button>
        )}
      </div>

      {/* ── Create New tab ── */}
      {mode === 'create' && (
        <CreateNewTaskForm
          form={form}
          userId={userId}
          onCompositeCreated={(ct: CompositeTask) => {
            // Composites aren't added directly to the board pool — BoardTask.taskId
            // references the tasks table, not compositeTasks. Users add the
            // composite's individual leaf/subtasks via the Existing Tasks tab.
            showSuccess(`Created composite "${ct.title}". Add its subtasks from Existing Tasks.`);
          }}
        />
      )}

      {/* ── Existing Tasks tab ── */}
      {mode === 'existing' && (
        <div className={styles.modeSection}>
          <FilterTabs
            tabs={EXISTING_FILTER_TABS}
            activeTab={existingFilter}
            onTabChange={(value) => handleExistingFilterChange(value as ExistingFilter)}
          />

          {filteredTasks.length === 0 && filteredCompositeTasks.length === 0 ? (
            <div className={styles.emptyState}>
              <div className={styles.emptyIcon} aria-hidden="true">+</div>
              <p>No tasks yet. Create your first task above!</p>
            </div>
          ) : (
            <div className={styles.taskList}>
              {filteredTasks.map((task: Task) => (
                <div key={task.id}>
                  <div className={styles.taskItem}>
                    <div className={styles.taskItemInfo}>
                      <span className={styles.taskItemTitle}>{task.title}</span>
                      <TypeBadge type={task.type} size="small" />
                    </div>
                    <div className={styles.taskItemActions}>
                      {canDerive(task.type) && (
                        <button
                          type="button"
                          className={`${styles.deriveButton} ${expandedTaskId === task.id ? styles.deriveButtonActive : ''}`}
                          onClick={() => toggleExpand(task.id)}
                          aria-label={expandedTaskId === task.id ? `Collapse ${task.title} derivation` : `Derive subtasks from ${task.title}`}
                          aria-expanded={expandedTaskId === task.id}
                        >
                          {expandedTaskId === task.id ? '\u25BC' : '\u25B6'}
                        </button>
                      )}
                      {isInPool(task.id) ? (
                        <span className={styles.inPoolBadge}>In Pool</span>
                      ) : (
                        <button
                          type="button"
                          className={styles.addButton}
                          onClick={() => {
                            addToPool({ taskId: task.id, title: task.title, type: task.type });
                            showSuccess(`Added to board pool: "${task.title}"`);
                          }}
                        >
                          Add
                        </button>
                      )}
                    </div>
                  </div>
                  {expandedTaskId === task.id && renderInlineTaskPanel(task)}
                </div>
              ))}

              {filteredCompositeTasks.map((ct: CompositeTask) => (
                <div key={ct.id}>
                  <div className={styles.taskItem}>
                    <div className={styles.taskItemInfo}>
                      <span className={styles.taskItemTitle}>{ct.title}</span>
                      <TypeBadge type="composite" size="small" />
                    </div>
                    <div className={styles.taskItemActions}>
                      <button
                        type="button"
                        className={`${styles.deriveButton} ${expandedTaskId === ct.id ? styles.deriveButtonActive : ''}`}
                        onClick={() => toggleExpand(ct.id)}
                        aria-label={expandedTaskId === ct.id ? `Collapse ${ct.title} subtasks` : `Show subtasks of ${ct.title}`}
                        aria-expanded={expandedTaskId === ct.id}
                      >
                        {expandedTaskId === ct.id ? '\u25BC' : '\u25B6'}
                      </button>
                    </div>
                  </div>
                  {expandedTaskId === ct.id && renderInlineCompositePanel(ct)}
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* ── Board Task Pool — always visible ── */}
      <div id="create-board-task-pool" className={styles.poolSection}>
        <h4 className={styles.poolTitle}>
          Board Task Pool
          {boardPool.length > 0 && (
            <span className={styles.poolCount}>{boardPool.length}</span>
          )}
        </h4>
        {boardPool.length === 0 ? (
          <p className={styles.emptyStateInline}>
            No tasks in the pool yet. Use the tabs above to add tasks.
          </p>
        ) : (
          <div className={styles.poolList}>
            {boardPool.map((entry) => (
              <PoolItem
                key={entry.taskId}
                title={entry.title}
                type={entry.type}
                onRemove={() => removeFromPool(entry.taskId)}
              />
            ))}
            <button
              type="button"
              className={styles.poolClearButton}
              onClick={clearPool}
            >
              Clear Pool
            </button>
          </div>
        )}
      </div>

      {/* ── Board Creator — shown when pool has tasks ── */}
      {boardPool.length > 0 && userId && preferencesReady && (
        <BoardCreatorPanel
          pool={boardPool}
          taskMap={taskMap}
          allTaskSteps={allTaskSteps}
          userId={userId}
          initialPreferences={preferences}
          onBoardCreated={(boardId: string) => {
            navigate(`/boards/${boardId}`);
          }}
        />
      )}
    </div>
  );
}
