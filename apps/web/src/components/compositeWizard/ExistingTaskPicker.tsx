import { useMemo, useState } from 'react';
import type { CompositeTask, Task } from '@oybc/shared';
import { TaskType, generateCounterTaskTitle } from '@oybc/shared';
import { TypeBadge } from '../TypeBadge';
import { FilterTabs } from '../FilterTabs';
import styles from './ExistingTaskPicker.module.css';

/** Preview payload for a composite: first few leaf titles + total. */
export interface CompositeLeafPreview {
  titles: string[];
  totalLeaves: number;
}

type PickerFilter = 'all' | 'normal' | 'counting' | 'progress' | 'composite';

const FILTER_TABS: { value: PickerFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'normal', label: 'Normal' },
  { value: 'counting', label: 'Counting' },
  { value: 'progress', label: 'Progress' },
  { value: 'composite', label: 'Composite' },
];

export interface ExistingTaskPickerProps {
  /** Currently selected id — empty string when nothing is picked. */
  selectedId: string;
  /** Full library, pre-filtered at the card level to exclude ids picked by
   *  OTHER subtask cards (dedup lives upstream). */
  allTasks: Task[];
  allCompositeTasks: CompositeTask[];
  /** Ids picked by other cards — still filtered upstream, but passed in
   *  so the picker can also exclude its own dropdown rows. */
  excludedIds: Set<string>;
  /** taskId → number of non-deleted boards it's placed on. */
  taskBoardCounts: Record<string, number>;
  /** taskId → number of steps (progress tasks only). */
  taskStepCounts: Record<string, number>;
  /** compositeTaskId → leaf count. */
  compositeSubtaskCounts: Record<string, number>;
  /** compositeTaskId → first-few leaf title preview. */
  compositeLeafPreviews: Record<string, CompositeLeafPreview>;
  /** Invoked when the user selects a row. `kind` routes the write into
   *  `selectedTaskId` vs `selectedCompositeId` upstream. */
  onSelect: (id: string, kind: 'task' | 'composite') => void;
}

/** Internal row shape — a normalised view over both libraries. */
interface PickerRow {
  id: string;
  title: string;
  /** Type label used for the badge component AND for filter matching. */
  type: 'normal' | 'counting' | 'progress' | 'composite';
  /** Small descriptor shown under the title — may be empty. */
  subtitle: string;
  /** Trailing usage hint (`on 3 boards`, `4 subtasks`, `not on any board`). */
  usageHint: string;
  kind: 'task' | 'composite';
}

/**
 * ExistingTaskPicker — Inline expandable list used inside a composite
 * Build-step subtask card. Collapsed when the card already has a
 * selection; expanded (with search + filter + scrollable rows) when
 * the card is empty or the user clicked `Change`. Replaces the earlier
 * native `<select>` dropdown.
 */
export function ExistingTaskPicker({
  selectedId,
  allTasks,
  allCompositeTasks,
  excludedIds,
  taskBoardCounts,
  taskStepCounts,
  compositeSubtaskCounts,
  compositeLeafPreviews,
  onSelect,
}: ExistingTaskPickerProps): React.ReactElement {
  // Auto-expanded when nothing is picked yet; collapsed after a selection.
  const [isOpen, setIsOpen] = useState<boolean>(selectedId === '');
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<PickerFilter>('all');

  // Build the flat row list once per input change. Sorted alphabetically
  // by title so the order is predictable regardless of task age.
  const rows = useMemo<PickerRow[]>(() => {
    const taskRows: PickerRow[] = allTasks
      .filter((t) => !excludedIds.has(t.id) || t.id === selectedId)
      .map((t) => {
        const boards = taskBoardCounts[t.id] ?? 0;
        return {
          id: t.id,
          title: t.title,
          type: t.type as 'normal' | 'counting' | 'progress',
          subtitle: buildTaskSubtitle(t, taskStepCounts),
          usageHint: boards === 0 ? 'not on any board' : `on ${boards} board${boards === 1 ? '' : 's'}`,
          kind: 'task',
        };
      });
    const compositeRows: PickerRow[] = allCompositeTasks
      .filter((ct) => !excludedIds.has(ct.id) || ct.id === selectedId)
      .map((ct) => {
        const leaves = compositeSubtaskCounts[ct.id] ?? 0;
        return {
          id: ct.id,
          title: ct.title,
          type: 'composite',
          subtitle: buildCompositeSubtitle(ct.id, compositeLeafPreviews),
          usageHint: `${leaves} subtask${leaves === 1 ? '' : 's'}`,
          kind: 'composite',
        };
      });
    return [...taskRows, ...compositeRows].sort((a, b) =>
      a.title.localeCompare(b.title),
    );
  }, [
    allTasks,
    allCompositeTasks,
    excludedIds,
    selectedId,
    taskBoardCounts,
    taskStepCounts,
    compositeSubtaskCounts,
    compositeLeafPreviews,
  ]);

  // Apply search + filter to the flat list.
  const q = query.trim().toLowerCase();
  const visibleRows = rows.filter((row) => {
    if (filter !== 'all' && row.type !== filter) return false;
    if (q.length === 0) return true;
    return (
      row.title.toLowerCase().includes(q) ||
      row.subtitle.toLowerCase().includes(q)
    );
  });

  const selectedRow = selectedId ? rows.find((r) => r.id === selectedId) : null;

  // ─── Collapsed view ──────────────────────────────────────────────────────

  if (!isOpen && selectedRow) {
    return (
      <div className={styles.collapsedSummary}>
        <TypeBadge type={selectedRow.type} size="small" letterOnly />
        <div className={styles.collapsedCenter}>
          <span className={styles.collapsedTitle}>{selectedRow.title}</span>
          {selectedRow.subtitle && (
            <span className={styles.collapsedSubtitle}>{selectedRow.subtitle}</span>
          )}
        </div>
        <span className={styles.collapsedUsage}>{selectedRow.usageHint}</span>
        <button
          type="button"
          className={styles.changeButton}
          onClick={() => setIsOpen(true)}
        >
          Change
        </button>
      </div>
    );
  }

  // ─── Expanded view ───────────────────────────────────────────────────────

  const showEmptyLibrary = rows.length === 0;
  const showNoMatches = !showEmptyLibrary && visibleRows.length === 0;

  return (
    <div className={styles.expanded}>
      <div className={styles.searchRow}>
        <input
          type="search"
          className={styles.searchInput}
          placeholder="Search your tasks…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search tasks"
        />
      </div>

      <FilterTabs
        tabs={FILTER_TABS}
        activeTab={filter}
        onTabChange={(v) => setFilter(v as PickerFilter)}
      />

      <div className={styles.listContainer}>
        {showEmptyLibrary && (
          <div className={styles.emptyState}>
            Your library is empty — create a task with + Create new task.
          </div>
        )}
        {showNoMatches && (
          <div className={styles.emptyState}>
            {q.length > 0
              ? `No matches for "${query.trim()}" in ${filter === 'all' ? 'All' : filter}.`
              : filter === 'all'
                ? 'All of your tasks are already picked by other cards.'
                : `No ${filter} tasks available — try a different filter.`}
          </div>
        )}
        {!showEmptyLibrary && !showNoMatches && (
          <ul className={styles.rowList}>
            {visibleRows.map((row) => {
              const isSelected = row.id === selectedId;
              return (
                <li key={row.id}>
                  <button
                    type="button"
                    className={
                      isSelected ? styles.rowButtonSelected : styles.rowButton
                    }
                    onClick={() => {
                      onSelect(row.id, row.kind);
                      setIsOpen(false);
                    }}
                    aria-pressed={isSelected}
                  >
                    <TypeBadge type={row.type} size="small" letterOnly />
                    <div className={styles.rowCenter}>
                      <span className={styles.rowTitle}>{row.title}</span>
                      {row.subtitle && (
                        <span className={styles.rowSubtitle}>{row.subtitle}</span>
                      )}
                    </div>
                    <span className={styles.rowUsage}>{row.usageHint}</span>
                  </button>
                </li>
              );
            })}
          </ul>
        )}
      </div>

      {selectedRow !== null && selectedRow !== undefined && (
        <button
          type="button"
          className={styles.closePickerButton}
          onClick={() => setIsOpen(false)}
        >
          Keep "{selectedRow.title}"
        </button>
      )}
    </div>
  );
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Builds the subtitle line shown under a task's title in the picker.
 * Counting tasks surface the underlying action/max/unit so users can see
 * "what the task does" even when a custom title hides it. Progress tasks
 * surface step count. Normal tasks have no subtitle.
 */
function buildTaskSubtitle(
  task: Task,
  taskStepCounts: Record<string, number>,
): string {
  if (task.type === TaskType.COUNTING) {
    const { action, maxCount, unit } = task;
    if (!action || !unit || maxCount === undefined) return '';
    const derived = generateCounterTaskTitle(action, maxCount, unit);
    // Suppress the subtitle if it would just duplicate the title.
    return derived.toLowerCase() === task.title.trim().toLowerCase() ? '' : derived;
  }
  if (task.type === TaskType.PROGRESS) {
    const n = taskStepCounts[task.id] ?? 0;
    if (n === 0) return '';
    return `${n} step${n === 1 ? '' : 's'}`;
  }
  return '';
}

/**
 * Builds the subtitle line for a composite row: "leaf1, leaf2, leaf3
 * [+N more]". The trailing leaf count is duplicated in the usage hint,
 * so the subtitle carries the qualitative preview only.
 */
function buildCompositeSubtitle(
  compositeId: string,
  previews: Record<string, CompositeLeafPreview>,
): string {
  const preview = previews[compositeId];
  if (!preview) return '';
  const { titles, totalLeaves } = preview;
  if (titles.length === 0) return '';
  const visible = titles.join(', ');
  const hidden = totalLeaves - titles.length;
  return hidden > 0 ? `${visible}, +${hidden} more` : visible;
}
