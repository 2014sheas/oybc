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

/**
 * TasksFilterControls — Search + type-chip-row + (status / usage / sort)
 * dropdowns for the Tasks tab. Layout is intentionally stacked instead
 * of a single mega-row so it stays readable on phone widths.
 *
 * State lives in the parent (`useTasksFilters`). This component is
 * fully controlled.
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
}: TasksFilterControlsProps): React.ReactElement {
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
      </div>

      <div role="group" aria-label="Filter by task type">
        <FilterTabs
          tabs={TYPE_TABS}
          activeTab={typeFilter}
          onTabChange={(v) => onTypeFilterChange(v as TypeFilter)}
        />
      </div>

      <div className={styles.dropdownRow}>
        <label className={styles.dropdownLabel}>
          <span className={styles.dropdownLabelText}>Status</span>
          <select
            className={styles.dropdown}
            value={statusFilter}
            onChange={(e) => onStatusFilterChange(e.target.value as StatusFilter)}
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
      </div>
    </div>
  );
}
