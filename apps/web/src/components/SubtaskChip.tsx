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
  /**
   * Optional: when provided, the chip body becomes clickable and calls
   * this callback. Edit and remove buttons remain on their own elements
   * (stopPropagation prevents the body click from firing when those are
   * used). When omitted, the chip body is non-interactive.
   */
  onView?: () => void;
}

/**
 * SubtaskChip — Compact chip showing a confirmed subtask selection.
 *
 * Displays a type badge, title, and edit/remove action buttons in a
 * single horizontal row. Used in the composite task form to show
 * subtasks that have been confirmed by the user.
 *
 * When `onView` is provided the chip body acts as a button that opens
 * the task's library detail; the existing edit/remove icons remain
 * their own discrete buttons with stopPropagation so they don't fire
 * the body click.
 *
 * @param title - Display title
 * @param type - Task type for the badge
 * @param onEdit - Called when the edit button is clicked
 * @param onRemove - Called when the remove button is clicked
 * @param onView - Optional: called when the chip body is clicked
 */
export function SubtaskChip({ title, type, onEdit, onRemove, onView }: SubtaskChipProps): React.ReactElement {
  const body = (
    <>
      <TypeBadge type={type} />
      <span className={styles.subtaskChipTitle}>{title}</span>
      <div className={styles.subtaskChipActions}>
        <button
          type="button"
          className={styles.subtaskChipEditButton}
          onClick={(e) => { e.stopPropagation(); onEdit(); }}
          aria-label="Edit"
        >
          ✏
        </button>
        <button
          type="button"
          className={styles.subtaskChipRemoveButton}
          onClick={(e) => { e.stopPropagation(); onRemove(); }}
          aria-label="Remove"
        >
          ✕
        </button>
      </div>
    </>
  );

  if (onView) {
    return (
      <button
        type="button"
        className={styles.subtaskChip}
        onClick={onView}
        aria-label={`View details for ${title}`}
      >
        {body}
      </button>
    );
  }

  return (
    <div className={styles.subtaskChip}>
      {body}
    </div>
  );
}
