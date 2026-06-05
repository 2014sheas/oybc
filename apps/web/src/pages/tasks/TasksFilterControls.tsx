import { useState } from 'react';
import { FilterTabs } from '../../components/FilterTabs';
import type {
  SortOption,
  StatusFilter,
  TypeFilter,
  UsageFilter,
} from './useTasksFilters';
import styles from './TasksFilterControls.module.css';

export interface TasksFilterControlsProps {
  search: string;
  onSearchChange: (value: string) => void;
  typeFilter: TypeFilter;
  onTypeFilterChange: (value: TypeFilter) => void;
  statusFilter: StatusFilter;
  onStatusFilterChange: (value: StatusFilter) => void;
  usageFilter: UsageFilter;
  onUsageFilterChange: (value: UsageFilter) => void;
  sortBy: SortOption;
  onSortByChange: (value: SortOption) => void;
  /** Phase 6.Y — Timeboxed Tasks. When false (the default), the list
   *  hides tasks whose `endDate < now`. Toggle to show them. */
  showExpired: boolean;
  onShowExpiredChange: (value: boolean) => void;
  /** Issue #73 — when true (the default), compound children without direct
   *  placements are nested under their parent instead of shown at top level.
   *  Toggle to flatten. */
  groupByCompound: boolean;
  onGroupByCompoundChange: (value: boolean) => void;
}

const TYPE_TABS: { value: TypeFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'normal', label: 'Normal' },
  { value: 'counting', label: 'Counting' },
  { value: 'progress', label: 'Progress' },
  { value: 'composite', label: 'Composite' },
  { value: 'achievement', label: 'Achievement' },
];

const STATUS_OPTIONS: { value: StatusFilter; label: string }[] = [
  { value: 'any', label: 'Any status' },
  { value: 'completed', label: 'Completed' },
  { value: 'in-progress', label: 'In progress' },
  { value: 'never-started', label: 'Never started' },
];

const USAGE_OPTIONS: { value: UsageFilter; label: string }[] = [
  { value: 'any', label: 'Any usage' },
  { value: 'unused', label: 'Unused' },
  { value: 'on-active-boards', label: 'On active boards' },
];

const SORT_OPTIONS: { value: SortOption; label: string }[] = [
  { value: 'updated-desc', label: 'Recently updated' },
  { value: 'created-desc', label: 'Recently created' },
  { value: 'completed-desc', label: 'Recently completed' },
  { value: 'title-asc', label: 'Title (A→Z)' },
  { value: 'most-used-desc', label: 'Most-used' },
];

const DEFAULT_SORT: SortOption = 'updated-desc';
const DEFAULT_STATUS: StatusFilter = 'any';
const DEFAULT_USAGE: UsageFilter = 'any';
const DEFAULT_SHOW_EXPIRED = false;
const DEFAULT_GROUP_BY_COMPOUND = true;

/**
 * TasksFilterControls — Two primary rows (search + type chips) always
 * visible; secondary controls (Sort / Status / Usage) tuck behind a
 * "Filters" disclosure button so the default state doesn't clutter
 * the page above the library. A dot badge on the disclosure indicates
 * when any secondary filter is non-default, and a "Clear all" link
 * inside the expanded panel resets the secondary filters in one tap.
 *
 * State lives in the parent (`useTasksFilters`). The disclosure
 * open/closed state is local — re-collapses when the user navigates
 * away (parity with iOS, where the .sheet pattern would discard the
 * SwiftUI view state anyway).
 */
export function TasksFilterControls({
  search,
  onSearchChange,
  typeFilter,
  onTypeFilterChange,
  statusFilter,
  onStatusFilterChange,
  usageFilter,
  onUsageFilterChange,
  sortBy,
  onSortByChange,
  showExpired,
  onShowExpiredChange,
  groupByCompound,
  onGroupByCompoundChange,
}: TasksFilterControlsProps): React.ReactElement {
  const [isExpanded, setIsExpanded] = useState(false);

  const isAnyFilterActive =
    sortBy !== DEFAULT_SORT ||
    statusFilter !== DEFAULT_STATUS ||
    usageFilter !== DEFAULT_USAGE ||
    showExpired !== DEFAULT_SHOW_EXPIRED ||
    groupByCompound !== DEFAULT_GROUP_BY_COMPOUND;

  const handleClearAll = (): void => {
    onSortByChange(DEFAULT_SORT);
    onStatusFilterChange(DEFAULT_STATUS);
    onUsageFilterChange(DEFAULT_USAGE);
    onShowExpiredChange(DEFAULT_SHOW_EXPIRED);
    onGroupByCompoundChange(DEFAULT_GROUP_BY_COMPOUND);
  };

  return (
    <div className={styles.controls}>
      <div className={styles.searchRow}>
        <input
          type="search"
          className={styles.search}
          placeholder="Search tasks…"
          value={search}
          onChange={(e) => onSearchChange(e.target.value)}
          aria-label="Search tasks"
        />
        <button
          type="button"
          className={styles.disclosure}
          onClick={() => setIsExpanded((v) => !v)}
          aria-expanded={isExpanded}
          aria-controls="tasks-filters-panel"
        >
          <span>Filters</span>
          <span aria-hidden="true">{isExpanded ? '▴' : '▾'}</span>
          {isAnyFilterActive && (
            <span
              className={styles.badge}
              aria-label="Filters active"
              title="Filters active"
            />
          )}
        </button>
      </div>

      <div role="group" aria-label="Filter by task type">
        <FilterTabs
          tabs={TYPE_TABS}
          activeTab={typeFilter}
          onTabChange={(v) => onTypeFilterChange(v as TypeFilter)}
        />
      </div>

      {/* Issue #73 — Group subtasks chip. Placed after type chips so it reads
          as a secondary modifier, not a type filter. Pill style matches the
          wizard's "From parent boards" chip. */}
      <div className={styles.groupChipRow}>
        <button
          type="button"
          className={`${styles.groupChip} ${groupByCompound ? styles.groupChipActive : ''}`}
          onClick={() => onGroupByCompoundChange(!groupByCompound)}
          aria-pressed={groupByCompound}
          title={
            groupByCompound
              ? 'Grouping ON — subtasks nested under parent. Tap to show flat list.'
              : 'Grouping OFF — all tasks at top level. Tap to group subtasks under parents.'
          }
        >
          {groupByCompound ? 'Group subtasks ✓' : 'Group subtasks'}
        </button>
      </div>

      {isExpanded && (
        <div
          id="tasks-filters-panel"
          className={styles.expandedPanel}
          role="group"
          aria-label="Secondary filters"
        >
          <label className={styles.dropdownLabel}>
            <span className={styles.dropdownLabelText}>Sort</span>
            <select
              className={styles.dropdown}
              value={sortBy}
              onChange={(e) => onSortByChange(e.target.value as SortOption)}
            >
              {SORT_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </label>
          <label className={styles.dropdownLabel}>
            <span className={styles.dropdownLabelText}>Status</span>
            <select
              className={styles.dropdown}
              value={statusFilter}
              onChange={(e) =>
                onStatusFilterChange(e.target.value as StatusFilter)
              }
            >
              {STATUS_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </label>
          <label className={styles.dropdownLabel}>
            <span className={styles.dropdownLabelText}>Usage</span>
            <select
              className={styles.dropdown}
              value={usageFilter}
              onChange={(e) => onUsageFilterChange(e.target.value as UsageFilter)}
            >
              {USAGE_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </label>
          <label className={styles.dropdownLabel}>
            <input
              type="checkbox"
              checked={showExpired}
              onChange={(e) => onShowExpiredChange(e.target.checked)}
            />
            <span className={styles.dropdownLabelText}>Show expired tasks</span>
          </label>
          {isAnyFilterActive && (
            <button
              type="button"
              className={styles.clearAll}
              onClick={handleClearAll}
            >
              Clear all
            </button>
          )}
        </div>
      )}
    </div>
  );
}
