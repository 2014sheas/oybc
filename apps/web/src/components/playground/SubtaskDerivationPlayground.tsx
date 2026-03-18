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
import { useTasks, useTaskSteps } from '../../hooks';
import { PLAYGROUND_USER_ID } from './playgroundUtils';
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
 * Returns the CSS class suffix for a task type badge.
 *
 * @param type - Task type string
 * @returns Capitalised type string matching the CSS module convention
 */
function typeBadgeClass(type: string): string {
  return type.charAt(0).toUpperCase() + type.slice(1);
}

/**
 * Returns the human-readable operator description for a composite's root operator.
 *
 * @param operatorType - The OperatorType enum value
 * @param threshold - Required for M_OF_N; the minimum count
 * @param leafCount - Total number of leaf nodes
 * @returns Display string such as "AND (all required)"
 */
function formatOperatorLabel(
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
}

/**
 * CountingDerivationPanel — shown when the selected parent is a counting task.
 *
 * Displays parent counting metadata and allows the user to enter a partial count
 * allocation, with a live preview of the derived subtask title.
 *
 * @param task - The selected counting task
 * @param partialCount - Current partial count input value (as string)
 * @param onPartialCountChange - Callback when the partial count field changes
 */
function CountingDerivationPanel({
  task,
  partialCount,
  onPartialCountChange,
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
    </>
  );
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * Props for ProgressDerivationPanel.
 */
interface ProgressDerivationPanelProps {
  taskId: string;
}

/**
 * ProgressDerivationPanel — shown when the selected parent is a progress task.
 *
 * Reactively fetches and displays all steps, including type metadata and whether
 * each step already has a linked task.
 *
 * @param taskId - The ID of the selected progress task
 */
function ProgressDerivationPanel({ taskId }: ProgressDerivationPanelProps): React.ReactElement {
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
            <span
              className={`${styles.typeBadge} ${styles[`typeBadge${typeBadgeClass(step.type)}`]}`}
            >
              {step.type.toUpperCase()}
            </span>

            {/* Linked task badge */}
            {step.linkedTaskId ? (
              <span className={styles.linkedBadge}>Existing Task</span>
            ) : (
              <span className={styles.unlinkedBadge}>Will Create New Task</span>
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
  const operatorDisplay = formatOperatorLabel(operatorType, rootNode.threshold, leafNodes.length);

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

            if (leaf.taskId && taskMap[leaf.taskId]) {
              const referencedTask = taskMap[leaf.taskId];
              leafTitle = referencedTask.title;
              badgeType = referencedTask.type;
            } else if (leaf.childCompositeTaskId && compositeTaskMap[leaf.childCompositeTaskId]) {
              leafTitle = compositeTaskMap[leaf.childCompositeTaskId].title;
              badgeType = 'composite';
            }

            return (
              <li key={leaf.id} className={styles.leafItem}>
                <span className={styles.leafBullet}>·</span>
                <span className={styles.leafTitle}>{leafTitle}</span>
                <span
                  className={`${styles.typeBadge} ${styles[`typeBadge${typeBadgeClass(badgeType)}`]}`}
                >
                  {badgeType.toUpperCase()}
                </span>
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
 * SubtaskDerivationPlayground — Read-only feature playground.
 *
 * Allows users to select a parent task from the task library and inspect what
 * subtasks can be derived from it. Derivation panels vary by task type:
 * - Normal: informational message (no sub-structure)
 * - Counting: allocation input with live generated-title preview
 * - Progress: reactive step list with link-status badges
 * - Composite: operator type and resolved leaf node list
 *
 * All data is read from the local Dexie database via reactive queries.
 * No database writes are performed by this component.
 */
export function SubtaskDerivationPlayground(): React.ReactElement {
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [filterType, setFilterType] = useState<FilterType>('all');
  const [partialCount, setPartialCount] = useState<string>('');

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
          />
        )}
        {task.type === TaskType.PROGRESS && (
          <ProgressDerivationPanel taskId={task.id} />
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
        />
      </div>
    );
  }

  return (
    <div className={styles.container}>
      {/* Filter tabs */}
      <div className={styles.filterTabs}>
        {FILTER_TABS.map((tab) => (
          <button
            key={tab.value}
            type="button"
            className={`${styles.filterTab} ${filterType === tab.value ? styles.filterTabActive : ''}`}
            onClick={() => handleFilterChange(tab.value)}
          >
            {tab.label}
          </button>
        ))}
      </div>

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
              <button
                type="button"
                className={`${styles.taskSelectorItem} ${
                  selectedTaskId === task.id ? styles.taskSelectorItemActive : ''
                }`}
                onClick={() => handleSelect(task.id)}
                aria-pressed={selectedTaskId === task.id}
              >
                <span className={styles.taskSelectorTitle}>{task.title}</span>
                <span
                  className={`${styles.typeBadge} ${styles[`typeBadge${typeBadgeClass(task.type)}`]}`}
                >
                  {task.type.toUpperCase()}
                </span>
              </button>
              {selectedTaskId === task.id && renderInlineTaskPanel(task)}
            </div>
          ))}

          {/* Composite tasks */}
          {filteredCompositeTasks.map((ct: CompositeTask) => (
            <div key={ct.id}>
              <button
                type="button"
                className={`${styles.taskSelectorItem} ${
                  selectedTaskId === ct.id ? styles.taskSelectorItemActive : ''
                }`}
                onClick={() => handleSelect(ct.id)}
                aria-pressed={selectedTaskId === ct.id}
              >
                <span className={styles.taskSelectorTitle}>{ct.title}</span>
                <span className={`${styles.typeBadge} ${styles.typeBadgeComposite}`}>
                  COMPOSITE
                </span>
              </button>
              {selectedTaskId === ct.id && renderInlineCompositePanel(ct)}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
