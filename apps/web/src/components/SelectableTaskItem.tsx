import { TypeBadge } from './TypeBadge';
import styles from './SelectableTaskItem.module.css';

interface SelectableTaskItemProps {
  /** Display title */
  title: string;
  /** Task type string for the badge */
  type: string;
  /** Whether this item is currently selected */
  isSelected: boolean;
  /** Callback when the item is clicked */
  onSelect: () => void;
}

/**
 * SelectableTaskItem — Clickable task list item with title, type badge, and selected state.
 *
 * Used in the subtask derivation playground as the selectable parent task list.
 * Shows a title and type badge, with active styling when selected.
 *
 * @param title - Display title
 * @param type - Task type for the badge
 * @param isSelected - Whether this item is active
 * @param onSelect - Called when clicked
 */
export function SelectableTaskItem({ title, type, isSelected, onSelect }: SelectableTaskItemProps): React.ReactElement {
  return (
    <button
      type="button"
      className={`${styles.taskSelectorItem} ${isSelected ? styles.taskSelectorItemActive : ''}`}
      onClick={onSelect}
      aria-pressed={isSelected}
    >
      <span className={styles.taskSelectorTitle}>{title}</span>
      <TypeBadge type={type} size="small" />
    </button>
  );
}
