import { useMemo, useState } from 'react';
import {
  TaskType,
  type Task,
  type CompositeTask,
} from '@oybc/shared';
import type { TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { TypeBadge } from '../TypeBadge';
import { FilterTabs } from '../FilterTabs';
import { CompositeDerivationPanel } from '../CompositeDerivationPanel';
import { NewTaskSheet } from './NewTaskSheet';
import styles from './BoardWizardTasksStep.module.css';

const FILTER_TABS: { value: TasksFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: TaskType.PROGRESS, label: 'Progress' },
  { value: 'composite', label: 'Composite' },
];

export type TasksFilter = 'all' | TaskType | 'composite';

export interface BoardWizardTasksStepProps {
  /** User's full task + composite library (from `useTaskLibrary`). */
  library: TaskLibrary;

  /** Currently-selected task ids — controlled by the wizard. */
  selectedTaskIds: Set<string>;
  /** Called when the user toggles a task's selection state. */
  onToggleSelection: (taskId: string) => void;

  /** Number of tasks the chosen board geometry requires. */
  tasksRequired: number;

  /** When true, every selected row shows a star radio for picking the
   *  center task. Driven by Step 1's center-type choice. */
  centerTaskMode: boolean;
  /** The currently-marked center task id, or `null` if none picked. */
  centerTaskId: string | null;
  /** Called when the user marks a different selected task as center. */
  onCenterTaskChange: (taskId: string | null) => void;

  /** Authenticated user id used by the inline new-task sheet. */
  userId: string;
  /** Fired after a non-composite task is created from the sheet — the
   *  wizard should auto-add the new id to `selectedTaskIds`. */
  onTaskCreated: (task: Task) => void;
  /** Fired after a composite task is created from the sheet — the
   *  wizard should reload the library so the composite shows up. */
  onCompositeCreated: (ct: CompositeTask) => void;

  /** Navigates to the previous wizard step. */
  onBack: () => void;
  /** Navigates to the next wizard step. Disabled when validation fails. */
  onNext: () => void;
}

/**
 * BoardWizardTasksStep — Step 2 of the board-creation wizard.
 *
 * Renders the user's task library with multi-select, a search input,
 * a type filter, and an inline "+ New task" sheet. Composite tasks
 * expand to their leaf nodes via the existing `CompositeDerivationPanel`
 * so leaves can be selected individually.
 *
 * The component is fully controlled — `selectedTaskIds`, `centerTaskId`,
 * and the navigation callbacks are owned by the wizard's state
 * controller. Internal state is limited to UI-only concerns
 * (search query, active filter, expanded composite, sheet open state).
 */
export function BoardWizardTasksStep({
  library,
  selectedTaskIds,
  onToggleSelection,
  tasksRequired,
  centerTaskMode,
  centerTaskId,
  onCenterTaskChange,
  userId,
  onTaskCreated,
  onCompositeCreated,
  onBack,
  onNext,
}: BoardWizardTasksStepProps): React.ReactElement {
  const [searchQuery, setSearchQuery] = useState('');
  const [activeFilter, setActiveFilter] = useState<TasksFilter>('all');
  const [expandedCompositeId, setExpandedCompositeId] = useState<string | null>(null);
  const [isSheetOpen, setIsSheetOpen] = useState(false);

  const visible = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    const matches = (title: string): boolean =>
      q.length === 0 || title.toLowerCase().includes(q);

    const tasks =
      activeFilter === 'all'
        ? library.allTasks.filter((t) => matches(t.title))
        : activeFilter === 'composite'
          ? []
          : library.allTasks.filter((t) => t.type === activeFilter && matches(t.title));

    const composites =
      activeFilter === 'all' || activeFilter === 'composite'
        ? library.allCompositeTasks.filter((ct) => matches(ct.title))
        : [];

    return { tasks, composites };
  }, [library, activeFilter, searchQuery]);

  const selectedCount = selectedTaskIds.size;
  const isCountSatisfied = selectedCount >= tasksRequired;
  const isCenterSatisfied =
    !centerTaskMode || (centerTaskId !== null && selectedTaskIds.has(centerTaskId));
  const canAdvance = isCountSatisfied && isCenterSatisfied;

  function handleToggle(taskId: string): void {
    const wasSelected = selectedTaskIds.has(taskId);
    onToggleSelection(taskId);
    // If the user is deselecting the current center task, clear the center mark.
    if (wasSelected && centerTaskId === taskId) {
      onCenterTaskChange(null);
    }
  }

  function handleCenterRadio(taskId: string): void {
    onCenterTaskChange(centerTaskId === taskId ? null : taskId);
  }

  function isLeafSelected(leafTaskId: string): boolean {
    return selectedTaskIds.has(leafTaskId);
  }

  function handleAddLeafToSelection(leafTaskId: string): void {
    onToggleSelection(leafTaskId);
  }

  return (
    <div className={styles.container}>
      {/* Header — selection count, search, filter */}
      <div className={styles.header}>
        <div className={styles.countRow}>
          <div className={styles.countGroup}>
            <span className={styles.countLabel}>
              Selected:{' '}
              <span className={isCountSatisfied ? styles.countOk : styles.countShort}>
                {selectedCount} / {tasksRequired}
              </span>
            </span>
            {centerTaskMode && (
              <span
                className={
                  centerTaskId !== null && selectedTaskIds.has(centerTaskId)
                    ? styles.centerBadgeOk
                    : styles.centerBadgeWarn
                }
              >
                {centerTaskId !== null && selectedTaskIds.has(centerTaskId)
                  ? '★ Center picked'
                  : '★ Center required'}
              </span>
            )}
          </div>
          <button
            type="button"
            className={styles.newTaskButton}
            onClick={() => setIsSheetOpen(true)}
          >
            + New task
          </button>
        </div>

        <input
          type="search"
          className={styles.search}
          placeholder="Search your tasks…"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
        />

        <FilterTabs
          tabs={FILTER_TABS}
          activeTab={activeFilter}
          onTabChange={(value) => {
            setActiveFilter(value as TasksFilter);
            setExpandedCompositeId(null);
          }}
        />
      </div>

      {/* List */}
      {visible.tasks.length === 0 && visible.composites.length === 0 ? (
        <div className={styles.emptyState}>
          {searchQuery.trim().length > 0
            ? `No tasks match "${searchQuery}".`
            : 'Your task library is empty. Tap "New task" above to create your first one.'}
        </div>
      ) : (
        <div className={styles.list}>
          {visible.tasks.map((task) => {
            const isSelected = selectedTaskIds.has(task.id);
            const isCenter = centerTaskId === task.id;
            return (
              <div
                key={task.id}
                className={`${styles.row} ${isSelected ? styles.rowSelected : ''}`}
              >
                <button
                  type="button"
                  className={styles.rowMain}
                  onClick={() => handleToggle(task.id)}
                  aria-pressed={isSelected}
                >
                  <span
                    className={`${styles.checkbox} ${isSelected ? styles.checkboxOn : ''}`}
                    aria-hidden="true"
                  >
                    {isSelected ? '✓' : ''}
                  </span>
                  <span className={styles.rowTitle}>{task.title}</span>
                  <TypeBadge type={task.type} size="small" />
                </button>
                {centerTaskMode && isSelected && (
                  <button
                    type="button"
                    className={`${styles.centerRadio} ${isCenter ? styles.centerRadioOn : ''}`}
                    onClick={() => handleCenterRadio(task.id)}
                    aria-label={isCenter ? 'Center task' : 'Mark as center task'}
                    aria-pressed={isCenter}
                    title={isCenter ? 'Center task' : 'Mark as center task'}
                  >
                    {isCenter ? '★' : '☆'}
                  </button>
                )}
              </div>
            );
          })}

          {visible.composites.map((ct) => {
            const isExpanded = expandedCompositeId === ct.id;
            return (
              <div key={ct.id} className={styles.compositeWrapper}>
                <div className={styles.row}>
                  <button
                    type="button"
                    className={styles.rowMain}
                    onClick={() =>
                      setExpandedCompositeId((prev) => (prev === ct.id ? null : ct.id))
                    }
                    aria-expanded={isExpanded}
                  >
                    <span
                      className={`${styles.expandToggle} ${isExpanded ? styles.expandToggleOpen : ''}`}
                      aria-hidden="true"
                    >
                      ▶
                    </span>
                    <span className={styles.rowTitle}>{ct.title}</span>
                    <TypeBadge type="composite" size="small" />
                  </button>
                </div>
                {isExpanded && (
                  <div className={styles.compositePanel}>
                    <p className={styles.compositeHint}>
                      Composites can't be boarded directly. Pick the individual subtasks you
                      want to include.
                    </p>
                    <CompositeDerivationPanel
                      compositeTask={ct}
                      allNodes={library.allCompositeNodes}
                      taskMap={library.taskMap}
                      compositeTaskMap={library.compositeTaskMap}
                      onAddLeafToPool={(taskId) => handleAddLeafToSelection(taskId)}
                      isInPool={isLeafSelected}
                    />
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* Footer — actions */}
      <div className={styles.footer}>
        <button type="button" className={styles.backButton} onClick={onBack}>
          ‹ Back
        </button>
        <button
          type="button"
          className={styles.nextButton}
          onClick={onNext}
          disabled={!canAdvance}
          title={
            !isCountSatisfied
              ? (() => {
                  const n = tasksRequired - selectedCount;
                  return `Pick ${n} more task${n === 1 ? '' : 's'}`;
                })()
              : !isCenterSatisfied
                ? 'Mark one selected task as the center'
                : undefined
          }
        >
          Next ›
        </button>
      </div>

      <NewTaskSheet
        isOpen={isSheetOpen}
        onClose={() => setIsSheetOpen(false)}
        userId={userId}
        onTaskCreated={(task) => {
          onTaskCreated(task);
        }}
        onCompositeCreated={(ct) => {
          onCompositeCreated(ct);
        }}
      />
    </div>
  );
}
