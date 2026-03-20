import { TypeBadge } from './TypeBadge';
import styles from './SubtaskChip.module.css';

interface SubtaskChipProps {
  /** Display title of the subtask */
  title: string;
  /** Task type string for the badge */
  type: string;
  /** Callback when the edit button is clicked */
  onEdit: () => void;
  /** Callback when the remove button is clicked */
  onRemove: () => void;
}

/**
 * SubtaskChip — Compact chip showing a confirmed subtask selection.
 *
 * Displays a type badge, title, and edit/remove action buttons in a
 * single horizontal row. Used in the composite task form to show
 * subtasks that have been confirmed by the user.
 *
 * @param title - Display title
 * @param type - Task type for the badge
 * @param onEdit - Called when the edit button is clicked
 * @param onRemove - Called when the remove button is clicked
 */
export function SubtaskChip({ title, type, onEdit, onRemove }: SubtaskChipProps): React.ReactElement {
  return (
    <div className={styles.subtaskChip}>
      <TypeBadge type={type} />
      <span className={styles.subtaskChipTitle}>{title}</span>
      <div className={styles.subtaskChipActions}>
        <button
          type="button"
          className={styles.subtaskChipEditButton}
          onClick={onEdit}
          aria-label="Edit"
        >
          ✏
        </button>
        <button
          type="button"
          className={styles.subtaskChipRemoveButton}
          onClick={onRemove}
          aria-label="Remove"
        >
          ✕
        </button>
      </div>
    </div>
  );
}
