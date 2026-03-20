import { TypeBadge } from './TypeBadge';
import styles from './PoolItem.module.css';

interface PoolItemProps {
  /** Display title */
  title: string;
  /** Task type string for the badge */
  type: string;
  /** Callback when the remove button is clicked */
  onRemove: () => void;
}

/**
 * PoolItem — Display item for board task pool entries with a remove button.
 *
 * Shows a title, type badge, and remove (×) button in a compact
 * horizontal row. Used in the subtask derivation playground's
 * Board Task Pool staging area.
 *
 * @param title - Display title
 * @param type - Task type for the badge
 * @param onRemove - Called when the remove button is clicked
 */
export function PoolItem({ title, type, onRemove }: PoolItemProps): React.ReactElement {
  return (
    <div className={styles.poolItem}>
      <span className={styles.poolItemTitle}>{title}</span>
      <TypeBadge type={type} size="small" />
      <button
        type="button"
        className={styles.poolRemoveButton}
        onClick={onRemove}
        title="Remove from pool"
        aria-label="Remove from pool"
      >
        ×
      </button>
    </div>
  );
}
