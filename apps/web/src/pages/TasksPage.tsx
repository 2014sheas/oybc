import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { NewTaskSheet } from '../components/wizard/NewTaskSheet';
import { useTaskLibrary } from './createPage/useTaskLibrary';
import { TasksFilterControls } from './tasks/TasksFilterControls';
import { TaskRow } from './tasks/TaskRow';
import { useTasksFilters } from './tasks/useTasksFilters';
import styles from './TasksPage.module.css';

export interface TasksPageProps {
  userId: string;
}

/**
 * TasksPage — Dedicated Tasks tab. Composes:
 * - Header row with a compact "+ New task" button; tapping it opens
 *   the existing `NewTaskSheet` modal so the form doesn't dominate
 *   the page (the library is the primary surface).
 * - Filter + sort controls (search + type chips + status / usage
 *   dropdowns + sort dropdown).
 * - Scrolling list of task rows; tapping a row deep-links into the
 *   detail page at `/tasks/:id`.
 *
 * Stateful concerns (filter / sort) live in `useTasksFilters`.
 * Library reads come from the shared `useTaskLibrary` hook so the
 * Tasks tab and the Create-wizard task-step both see the same data.
 */
export function TasksPage({ userId }: TasksPageProps): React.ReactElement {
  const navigate = useNavigate();
  const library = useTaskLibrary(userId);
  const filters = useTasksFilters(library);
  const [showNewTaskSheet, setShowNewTaskSheet] = useState(false);

  return (
    <div className={styles.shell}>
      <header className={styles.header}>
        <h1 className={styles.title}>Tasks</h1>
        <button
          type="button"
          className={styles.newTaskButton}
          onClick={() => setShowNewTaskSheet(true)}
        >
          + Create task
        </button>
      </header>

      <TasksFilterControls
        search={filters.search}
        onSearchChange={filters.setSearch}
        typeFilter={filters.typeFilter}
        onTypeFilterChange={filters.setTypeFilter}
        statusFilter={filters.statusFilter}
        onStatusFilterChange={filters.setStatusFilter}
        usageFilter={filters.usageFilter}
        onUsageFilterChange={filters.setUsageFilter}
        sortBy={filters.sortBy}
        onSortByChange={filters.setSortBy}
        showExpired={filters.showExpired}
        onShowExpiredChange={filters.setShowExpired}
      />

      {filters.filteredTasks.length === 0 ? (
        <EmptyState hasAnyTasks={library.allTasks.length > 0} />
      ) : (
        <ul className={styles.list} aria-label="Task list">
          {filters.filteredTasks.map((task) => (
            <li key={task.id}>
              <TaskRow
                task={task}
                placementCount={filters.placementCountByTaskId[task.id] ?? 0}
                activePlacementCount={
                  filters.activePlacementCountByTaskId[task.id] ?? 0
                }
                childCount={
                  library.compoundChildrenByCompound[task.id]?.length ?? 0
                }
                onClick={(id) => navigate(`/tasks/${id}`)}
              />
            </li>
          ))}
        </ul>
      )}

      <NewTaskSheet
        isOpen={showNewTaskSheet}
        onClose={() => setShowNewTaskSheet(false)}
        userId={userId}
        // Both callbacks fire after the sheet has already closed the
        // form on success. No extra reload is needed — `useTaskLibrary`
        // is reactive via `useLiveQuery` and picks up the new row
        // automatically.
        onTaskCreated={() => {}}
        onCompositeCreated={() => {}}
        submitLabel="Add to library"
      />
    </div>
  );
}

function EmptyState({
  hasAnyTasks,
}: {
  hasAnyTasks: boolean;
}): React.ReactElement {
  return (
    <section className={styles.empty}>
      {hasAnyTasks ? (
        <>
          <p className={styles.emptyTitle}>No tasks match your filters.</p>
          <p className={styles.emptyBody}>
            Try clearing the search, switching the type chip back to “All”, or
            resetting Status / Usage to “Any”.
          </p>
        </>
      ) : (
        <>
          <p className={styles.emptyTitle}>No tasks yet.</p>
          <p className={styles.emptyBody}>
            Tap “+ New task” to add one, or build a board on the Create tab —
            tasks you make there appear here too.
          </p>
        </>
      )}
    </section>
  );
}
