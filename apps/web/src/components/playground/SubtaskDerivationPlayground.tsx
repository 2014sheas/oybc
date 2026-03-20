import { useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType,
  OperatorType,
  generateCounterTaskTitle,
  type Task,
  type TaskStep,
  type CompositeTask,
  type CompositeNode,
} from '@oybc/shared';
import { db } from '../../db/database';
import { createTask } from '../../db/operations/tasks';
import { useTasks, useTaskSteps } from '../../hooks';
import { TypeBadge } from '../TypeBadge';
import { FilterTabs } from '../FilterTabs';
import { SelectableTaskItem } from '../SelectableTaskItem';
import { PoolItem } from '../PoolItem';
import { PLAYGROUND_USER_ID, SUCCESS_DISMISS_MS } from './playgroundUtils';
import styles from './SubtaskDerivationPlayground.module.css';

// ─── Filter tab configuration ─────────────────────────────────────────────────

type FilterType = 'all' | 'counting' | 'progress' | 'composite';

const FILTER_TABS: { value: FilterType; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'counting', label: 'Counting' },
  { value: 'progress', label: 'Progress' },
  { value: 'composite', label: 'Composite' },
];

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Returns the human-readable operator description for a composite's root operator.
 * Uses a more detailed format than the shared utility for the derivation context.
 *
 * @param operatorType - The OperatorType enum value
 * @param threshold - Required for M_OF_N; the minimum count
 * @param leafCount - Total number of leaf nodes
 * @returns Display string such as "AND (all required)"
 */
function formatOperatorLabelDetailed(
  operatorType: OperatorType,
  threshold: number | undefined,
  leafCount: number
): string {
  if (operatorType === OperatorType.AND) return 'AND (all required)';
  if (operatorType === OperatorType.OR) return 'OR (any one)';
  return `M_OF_N (at least ${threshold ?? '?'} of ${leafCount})`;
}

// ─── Sub-components ───────────────────────────────────────────────────────────

/**
 * NormalDerivationPanel — shown when the selected parent is a normal task.
 * Normal tasks have no sub-structure to derive from.
 */
function NormalDerivationPanel(): React.ReactElement {
  return (
    <p className={styles.normalMessage}>
      Normal tasks cannot be subdivided. Select a Counting, Progress, or Composite task to see
      derivation options.
    </p>
  );
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * Props for CountingDerivationPanel.
 */
interface CountingDerivationPanelProps {
  task: Task;
  partialCount: string;
  onPartialCountChange: (value: string) => void;
  onCreateSubtask: (task: Task, count: number) => Promise<void>;
  isCreating: boolean;
}

/**
 * CountingDerivationPanel — shown when the selected parent is a counting task.
 *
 * Displays parent counting metadata and allows the user to enter a partial count
 * allocation, with a live preview of the derived subtask title. Provides a
 * "Create Subtask" button to persist the derived task to the task library.
 *
 * @param task - The selected counting task
 * @param partialCount - Current partial count input value (as string)
 * @param onPartialCountChange - Callback when the partial count field changes
 * @param onCreateSubtask - Async callback invoked when the user clicks "Create Subtask"
 * @param isCreating - Whether a creation operation is in progress
 */
function CountingDerivationPanel({
  task,
  partialCount,
  onPartialCountChange,
  onCreateSubtask,
  isCreating,
}: CountingDerivationPanelProps): React.ReactElement {
  const action = task.action ?? '';
  const unit = task.unit ?? '';
  const maxCount = task.maxCount ?? 0;

  const parsedCount = parseInt(partialCount, 10);
  const isValid = partialCount !== '' && !isNaN(parsedCount) && parsedCount >= 1 && parsedCount <= maxCount;
  const isOutOfRange =
    partialCount !== '' && (!isNaN(parsedCount)) && (parsedCount < 1 || parsedCount > maxCount);
  const previewTitle = isValid
    ? generateCounterTaskTitle(action, parsedCount, unit)
    : null;

  return (
    <>
      {/* Parent counting metadata */}
      <div className={styles.countingMeta}>
        <div className={styles.countingMetaRow}>
          <span className={styles.metaLabel}>Action:</span>
          <span>{action || '—'}</span>
        </div>
        <div className={styles.countingMetaRow}>
          <span className={styles.metaLabel}>Unit:</span>
          <span>{unit || '—'}</span>
        </div>
        <div className={styles.countingMetaRow}>
          <span className={styles.metaLabel}>Parent total:</span>
          <span>{maxCount}</span>
        </div>
      </div>

      {/* Partial count allocation input */}
      <div className={styles.allocationField}>
        <label className={styles.allocationLabel} htmlFor="subtask-partial-count">
          Allocate count:
        </label>
        <input
          id="subtask-partial-count"
          type="number"
          className={`${styles.allocationInput} ${isOutOfRange ? styles.allocationInputError : ''}`}
          value={partialCount}
          min={1}
          max={maxCount}
          onChange={(e) => onPartialCountChange(e.target.value)}
          placeholder={`1 – ${maxCount}`}
        />
        {isOutOfRange && (
          <span className={styles.validationError}>
            Count must be between 1 and {maxCount}.
          </span>
        )}
      </div>

      {/* Live preview */}
      {isValid && previewTitle !== null && (
        <div className={styles.previewBox}>
          <span className={styles.previewLabel}>Derived subtask title preview</span>
          <span className={styles.previewTitle}>{previewTitle}</span>
        </div>
      )}

      {/* Create subtask action */}
      <button
        type="button"
        className={styles.actionButton}
        disabled={!isValid || isCreating}
        onClick={() => {
          if (isValid) {
            void onCreateSubtask(task, parsedCount);
          }
        }}
      >
        {isCreating ? 'Adding...' : 'Add to Board Pool'}
      </button>
    </>
  );
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * Props for ProgressDerivationPanel.
 */
interface ProgressDerivationPanelProps {
  taskId: string;
  onExtractStep: (step: TaskStep) => Promise<void>;
  onAddStepToPool: (step: TaskStep) => void;
  isCreating: boolean;
  isInPool: (taskId: string) => boolean;
}

/**
 * ProgressDerivationPanel — shown when the selected parent is a progress task.
 *
 * Reactively fetches and displays all steps, including type metadata and whether
 * each step already has a linked task. Unlinked steps show an "Extract as Task"
 * button to create a task record and link it.
 *
 * @param taskId - The ID of the selected progress task
 * @param onExtractStep - Async callback invoked to extract a step as a task
 * @param isCreating - Whether a creation operation is in progress
 */
function ProgressDerivationPanel({
  taskId,
  onExtractStep,
  onAddStepToPool,
  isCreating,
  isInPool,
}: ProgressDerivationPanelProps): React.ReactElement {
  const steps = useTaskSteps(taskId) ?? [];

  if (steps.length === 0) {
    return <p className={styles.emptyState}>No steps defined for this progress task.</p>;
  }

  return (
    <ol className={styles.stepList} style={{ listStyle: 'none', padding: 0, margin: 0 }}>
      {steps.map((step: TaskStep, index: number) => (
        <li key={step.id} className={styles.stepItem}>
          <span className={styles.stepIndex}>{index + 1}</span>

          <div className={styles.stepInfo}>
            <span className={styles.stepTitle}>{step.title}</span>
            {step.type === TaskType.COUNTING && step.action && step.unit && step.maxCount !== undefined && (
              <span className={styles.stepMeta}>
                {step.action} {step.maxCount} {step.unit}
              </span>
            )}
          </div>

          <div className={styles.stepBadges}>
            {/* Step type badge */}
            <TypeBadge type={step.type} size="small" />

            {/* Action: add to pool or extract first */}
            {step.linkedTaskId ? (
              isInPool(step.linkedTaskId) ? (
                <span className={styles.linkedBadge}>In Pool ✓</span>
              ) : (
                <button
                  type="button"
                  className={styles.actionButton}
                  onClick={() => onAddStepToPool(step)}
                >
                  Add to Pool
                </button>
              )
            ) : (
              <button
                type="button"
                className={styles.actionButton}
                disabled={isCreating}
                onClick={() => void onExtractStep(step)}
              >
                Extract & Add to Pool
              </button>
            )}
          </div>
        </li>
      ))}
    </ol>
  );
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * Props for CompositeDerivationPanel.
 */
interface CompositeDerivationPanelProps {
  compositeTask: CompositeTask;
  allNodes: CompositeNode[];
  taskMap: Record<string, Task>;
  compositeTaskMap: Record<string, CompositeTask>;
  onAddLeafToPool: (taskId: string, title: string, type: string) => void;
  isInPool: (taskId: string) => boolean;
}

/**
 * CompositeDerivationPanel — shown when the selected parent is a composite task.
 *
 * Resolves the root operator node and leaf nodes, displaying operator type and
 * each leaf with its referenced task or nested composite name.
 *
 * @param compositeTask - The selected composite task record
 * @param allNodes - All composite nodes (filtered to this composite's ID externally)
 * @param taskMap - Map of task ID → Task for name resolution
 * @param compositeTaskMap - Map of composite task ID → CompositeTask for name resolution
 */
function CompositeDerivationPanel({
  compositeTask,
  allNodes,
  taskMap,
  compositeTaskMap,
  onAddLeafToPool,
  isInPool,
}: CompositeDerivationPanelProps): React.ReactElement {
  const nodes = allNodes.filter((n) => n.compositeTaskId === compositeTask.id && !n.isDeleted);
  const rootNode = nodes.find((n) => n.id === compositeTask.rootNodeId);
  const leafNodes = nodes.filter((n) => n.nodeType === 'leaf');

  if (!rootNode || rootNode.nodeType !== 'operator' || !rootNode.operatorType) {
    return (
      <p className={styles.emptyState}>
        This composite task has no operator structure yet.
      </p>
    );
  }

  const operatorType = rootNode.operatorType as OperatorType;
  const operatorDisplay = formatOperatorLabelDetailed(operatorType, rootNode.threshold, leafNodes.length);

  return (
    <>
      {/* Operator row */}
      <div className={styles.operatorRow}>
        <span className={styles.operatorLabel}>Operator:</span>
        <span className={styles.operatorValue}>{operatorDisplay}</span>
      </div>

      {/* Leaf nodes */}
      {leafNodes.length === 0 ? (
        <p className={styles.emptyState}>No leaf nodes defined.</p>
      ) : (
        <ul className={styles.leafList} style={{ listStyle: 'none', padding: 0, margin: 0 }}>
          {leafNodes.map((leaf: CompositeNode) => {
            let leafTitle = '(unknown)';
            let badgeType = 'normal';
            let inLibrary = false;

            if (leaf.taskId && taskMap[leaf.taskId]) {
              const referencedTask = taskMap[leaf.taskId];
              leafTitle = referencedTask.title;
              badgeType = referencedTask.type;
              inLibrary = true;
            } else if (leaf.childCompositeTaskId && compositeTaskMap[leaf.childCompositeTaskId]) {
              leafTitle = compositeTaskMap[leaf.childCompositeTaskId].title;
              badgeType = 'composite';
              inLibrary = true;
            }

            return (
              <li key={leaf.id} className={styles.leafItem}>
                <span className={styles.leafBullet}>·</span>
                <span className={styles.leafTitle}>{leafTitle}</span>
                <TypeBadge type={badgeType} size="small" />
                {inLibrary && leaf.taskId && (
                  isInPool(leaf.taskId) ? (
                    <span className={styles.linkedBadge}>In Pool ✓</span>
                  ) : (
                    <button
                      type="button"
                      className={styles.actionButton}
                      onClick={() => onAddLeafToPool(leaf.taskId!, leafTitle, badgeType)}
                    >
                      Add to Pool
                    </button>
                  )
                )}
              </li>
            );
          })}
        </ul>
      )}
    </>
  );
}

// ─── Main component ───────────────────────────────────────────────────────────

/**
 * SubtaskDerivationPlayground — Feature playground for subtask creation.
 *
 * Allows users to select a parent task from the task library and inspect what
 * subtasks can be derived from it. Derivation panels vary by task type:
 * - Normal: informational message (no sub-structure)
 * - Counting: allocation input with live generated-title preview + "Create Subtask" button
 * - Progress: reactive step list with link-status badges + "Extract as Task" buttons
 * - Composite: operator type and resolved leaf node list with "In Library ✓" badges
 *
 * All reads are reactive via Dexie live queries. Writes use createTask() and
 * direct Dexie updates. Success messages auto-dismiss after SUCCESS_DISMISS_MS.
 */
/**
 * Entry in the Board Task Pool staging area.
 * Tracks the task ID, display title, and type for rendering.
 */
interface PoolEntry {
  taskId: string;
  title: string;
  type: string;
}

export function SubtaskDerivationPlayground(): React.ReactElement {
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [filterType, setFilterType] = useState<FilterType>('all');
  const [partialCount, setPartialCount] = useState<string>('');
  const [creationSuccess, setCreationSuccess] = useState<string | null>(null);
  const [isCreating, setIsCreating] = useState(false);
  const [boardPool, setBoardPool] = useState<PoolEntry[]>([]);

  // ── Success message helper ─────────────────────────────────────────────────

  /**
   * Shows a success message that auto-dismisses after SUCCESS_DISMISS_MS.
   *
   * @param message - The message string to display
   */
  function showSuccess(message: string): void {
    setCreationSuccess(message);
    setTimeout(() => setCreationSuccess(null), SUCCESS_DISMISS_MS);
  }

  // ── Reactive data sources ──────────────────────────────────────────────────

  /** All non-deleted tasks for the playground user, sorted by title */
  const allTasks = useTasks(PLAYGROUND_USER_ID) ?? [];

  /** All non-deleted composite tasks for the playground user */
  const allCompositeTasks =
    useLiveQuery(
      () =>
        db.compositeTasks
          .filter((ct: CompositeTask) => ct.userId === PLAYGROUND_USER_ID && !ct.isDeleted)
          .toArray(),
      []
    ) ?? [];

  /** All composite nodes (filtering per-composite happens in the panel) */
  const allCompositeNodes =
    useLiveQuery(
      () => db.compositeNodes.filter((n: CompositeNode) => !n.isDeleted).toArray(),
      []
    ) ?? [];

  // ── Derived lookup maps ────────────────────────────────────────────────────

  const taskMap: Record<string, Task> = {};
  for (const t of allTasks) taskMap[t.id] = t;

  const compositeTaskMap: Record<string, CompositeTask> = {};
  for (const ct of allCompositeTasks) compositeTaskMap[ct.id] = ct;

  // ── Filter logic ───────────────────────────────────────────────────────────

  /**
   * Returns tasks visible in the selector given the current filter tab.
   * Composite tasks are kept in a separate list and shown only when the filter
   * is 'all' or 'composite'.
   */
  const filteredTasks: Task[] =
    filterType === 'all'
      ? allTasks
      : filterType === 'composite'
        ? []
        : allTasks.filter((t: Task) => t.type === (filterType as TaskType));

  const filteredCompositeTasks: CompositeTask[] =
    filterType === 'all' || filterType === 'composite' ? allCompositeTasks : [];

  const totalVisible = filteredTasks.length + filteredCompositeTasks.length;

  // ── Selection resolution ───────────────────────────────────────────────────

  /**
   * Resolves the currently selected entity. Can be a Task or CompositeTask,
   * or null if nothing is selected or the selected ID no longer exists.
   */
  const selectedTask: Task | undefined = selectedTaskId ? taskMap[selectedTaskId] : undefined;
  const selectedComposite: CompositeTask | undefined = selectedTaskId
    ? compositeTaskMap[selectedTaskId]
    : undefined;

  // ── Handlers ──────────────────────────────────────────────────────────────

  /**
   * Selects a task or composite task by ID, resetting the counting input.
   *
   * @param id - The task or composite task ID to select
   */
  function handleSelect(id: string): void {
    setSelectedTaskId((prev) => (prev === id ? null : id));
    setPartialCount('');
  }

  /**
   * Changes the filter tab and clears the current selection if it would no
   * longer be visible under the new filter.
   *
   * @param newFilter - The filter type to apply
   */
  function handleFilterChange(newFilter: FilterType): void {
    setFilterType(newFilter);
    setPartialCount('');

    // Deselect if the current selection would be hidden
    if (selectedTaskId && selectedTask) {
      const nowVisible =
        newFilter === 'all' ||
        (newFilter !== 'composite' && selectedTask.type === (newFilter as TaskType));
      if (!nowVisible) setSelectedTaskId(null);
    } else if (selectedTaskId && selectedComposite) {
      const nowVisible = newFilter === 'all' || newFilter === 'composite';
      if (!nowVisible) setSelectedTaskId(null);
    }
  }

  /**
   * Adds a task to the board pool staging area. Skips duplicates.
   *
   * @param entry - The pool entry to add
   */
  function addToPool(entry: PoolEntry): void {
    setBoardPool((prev) => {
      if (prev.some((e) => e.taskId === entry.taskId)) return prev;
      return [...prev, entry];
    });
  }

  /**
   * Removes a task from the board pool by task ID.
   *
   * @param taskId - The task ID to remove
   */
  function removeFromPool(taskId: string): void {
    setBoardPool((prev) => prev.filter((e) => e.taskId !== taskId));
  }

  /**
   * Creates a counting subtask from a parent counting task and a partial count.
   * Persists the new task to the task library and adds it to the board pool.
   *
   * @param task - The parent counting task
   * @param count - The partial count to allocate to the subtask
   */
  async function handleCreateCountingSubtask(task: Task, count: number): Promise<void> {
    setIsCreating(true);
    try {
      const newTask = await createTask(PLAYGROUND_USER_ID, {
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

  /**
   * Extracts a progress task step as a standalone task, then links the step back
   * to the newly created task via its linkedTaskId field.
   *
   * @param step - The TaskStep to extract
   */
  async function handleExtractStep(step: TaskStep): Promise<void> {
    setIsCreating(true);
    try {
      const isCountingStep =
        step.type === TaskType.COUNTING &&
        step.action !== undefined &&
        step.unit !== undefined &&
        step.maxCount !== undefined;

      const newTask = await createTask(PLAYGROUND_USER_ID, {
        type: isCountingStep ? TaskType.COUNTING : TaskType.NORMAL,
        title: isCountingStep
          ? generateCounterTaskTitle(step.action!, step.maxCount!, step.unit!)
          : step.title,
        description: step.title !== (isCountingStep ? generateCounterTaskTitle(step.action!, step.maxCount!, step.unit!) : step.title)
          ? step.title
          : undefined,
        action: isCountingStep ? step.action! : undefined,
        unit: isCountingStep ? step.unit! : undefined,
        maxCount: isCountingStep ? step.maxCount! : undefined,
      });

      // Link the step to the newly created task
      await db.taskSteps.update(step.id, {
        linkedTaskId: newTask.id,
        updatedAt: new Date().toISOString(),
      });

      addToPool({ taskId: newTask.id, title: newTask.title, type: newTask.type });
      showSuccess(`Added to board pool: "${newTask.title}"`);
    } catch (err) {
      console.error('Failed to extract step as task:', err);
    } finally {
      setIsCreating(false);
    }
  }

  // ── Render ─────────────────────────────────────────────────────────────────

  /**
   * Renders the inline derivation panel for a regular task.
   * Shown directly below the selected task in the list.
   */
  function renderInlineTaskPanel(task: Task): React.ReactElement {
    return (
      <div className={styles.inlinePanel}>
        {task.type === TaskType.NORMAL && <NormalDerivationPanel />}
        {task.type === TaskType.COUNTING && (
          <CountingDerivationPanel
            task={task}
            partialCount={partialCount}
            onPartialCountChange={setPartialCount}
            onCreateSubtask={handleCreateCountingSubtask}
            isCreating={isCreating}
          />
        )}
        {task.type === TaskType.PROGRESS && (
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
            isInPool={(taskId: string) => boardPool.some((e) => e.taskId === taskId)}
          />
        )}
      </div>
    );
  }

  /**
   * Renders the inline derivation panel for a composite task.
   * Shown directly below the selected composite in the list.
   */
  function renderInlineCompositePanel(ct: CompositeTask): React.ReactElement {
    return (
      <div className={styles.inlinePanel}>
        <CompositeDerivationPanel
          compositeTask={ct}
          allNodes={allCompositeNodes}
          taskMap={taskMap}
          compositeTaskMap={compositeTaskMap}
          onAddLeafToPool={(taskId: string, title: string, type: string) => {
            addToPool({ taskId, title, type });
            showSuccess(`Added to board pool: "${title}"`);
          }}
          isInPool={(taskId: string) => boardPool.some((e) => e.taskId === taskId)}
        />
      </div>
    );
  }

  return (
    <div className={styles.container}>
      {/* Success message */}
      {creationSuccess && (
        <div className={styles.successMessage}>{creationSuccess}</div>
      )}

      {/* Filter tabs */}
      <FilterTabs
        tabs={FILTER_TABS}
        activeTab={filterType}
        onTabChange={(value) => handleFilterChange(value as FilterType)}
      />

      {/* Task list with inline derivation panels */}
      {totalVisible === 0 ? (
        <p className={styles.emptyState}>
          No tasks found. Create tasks using the Task Creation playground above.
        </p>
      ) : (
        <div className={styles.taskSelectorList}>
          {/* Regular tasks */}
          {filteredTasks.map((task: Task) => (
            <div key={task.id}>
              <SelectableTaskItem
                title={task.title}
                type={task.type}
                isSelected={selectedTaskId === task.id}
                onSelect={() => handleSelect(task.id)}
              />
              {selectedTaskId === task.id && renderInlineTaskPanel(task)}
            </div>
          ))}

          {/* Composite tasks */}
          {filteredCompositeTasks.map((ct: CompositeTask) => (
            <div key={ct.id}>
              <SelectableTaskItem
                title={ct.title}
                type="composite"
                isSelected={selectedTaskId === ct.id}
                onSelect={() => handleSelect(ct.id)}
              />
              {selectedTaskId === ct.id && renderInlineCompositePanel(ct)}
            </div>
          ))}
        </div>
      )}

      {/* Board Task Pool */}
      <div className={styles.poolSection}>
        <h4 className={styles.poolTitle}>
          Board Task Pool
          {boardPool.length > 0 && (
            <span className={styles.poolCount}>{boardPool.length}</span>
          )}
        </h4>
        {boardPool.length === 0 ? (
          <p className={styles.emptyState}>
            No tasks in the pool yet. Use the buttons above to add subtasks.
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
              onClick={() => setBoardPool([])}
            >
              Clear Pool
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
