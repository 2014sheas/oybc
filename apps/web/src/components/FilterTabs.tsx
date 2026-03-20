import styles from './FilterTabs.module.css';

interface Tab {
  value: string;
  label: string;
}

interface FilterTabsProps {
  /** Array of tab definitions with value and display label */
  tabs: Tab[];
  /** Currently active tab value */
  activeTab: string;
  /** Callback when a tab is clicked */
  onTabChange: (value: string) => void;
}

/**
 * FilterTabs — Horizontal pill-button group for filtering lists.
 *
 * Used in the task library and subtask derivation playground to filter
 * by task type (All / Normal / Counting / Progress / Composite).
 *
 * @param tabs - Tab definitions
 * @param activeTab - Currently selected tab value
 * @param onTabChange - Called with the new tab value on click
 */
export function FilterTabs({ tabs, activeTab, onTabChange }: FilterTabsProps): React.ReactElement {
  return (
    <div className={styles.filterTabs}>
      {tabs.map((tab) => (
        <button
          key={tab.value}
          type="button"
          className={`${styles.filterTab} ${activeTab === tab.value ? styles.filterTabActive : ''}`}
          onClick={() => onTabChange(tab.value)}
        >
          {tab.label}
        </button>
      ))}
    </div>
  );
}
