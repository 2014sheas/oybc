import type { Task } from '@oybc/shared';
import { BoardStatusBadge } from '../../components/BoardStatusBadge';
import { isBoardExpired } from '../../utils/boardDisplayUtils';
import type { TaskDeletionImpact } from '../../db/operations/tasks';
import styles from './TaskDetailContent.module.css';

export interface TaskConfirmDeleteDialogProps {
  task: Task;
  impact: TaskDeletionImpact;
  onConfirm: () => void;
  onCancel: () => void;
}

/**
 * TaskConfirmDeleteDialog — destructive confirmation sheet.
 *
 * Extracted from `TaskDetailContent` so the Tasks-tab row can present
 * the same dialog without navigating to the detail page first.
 * Enhanced from the original: when `impact.affectedBoards` is
 * non-empty, the dialog lists each board by name with a colored
 * status pill (Active / Completed / Draft / Expired) so the user can
 * decide whether the cascade is acceptable before confirming. Expired
 * boards are flagged in red — they're technically still ACTIVE in
 * status but past their endDate, and the original cascade reasoning
 * ("these placements still matter") is weaker for them.
 *
 * The trailing counts (compound child / parent link summaries) match
 * the previous dialog exactly, so the existing detail-page flow
 * shows the same information.
 */
export function TaskConfirmDeleteDialog({
  task,
  impact,
  onConfirm,
  onCancel,
}: TaskConfirmDeleteDialogProps): React.ReactElement {
  const hasBoards = impact.affectedBoards.length > 0;
  const otherCounts =
    impact.childLinkCount + impact.parentLinkCount;

  return (
    <div className={styles.sheetBackdrop} onClick={onCancel}>
      <div
        className={styles.sheet}
        role="alertdialog"
        aria-label="Confirm delete"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className={styles.sheetHeading}>Delete task?</h2>
        <p className={styles.confirmBody}>
          "{task.title || '(untitled task)'}" will be removed from your library.
          This can't be undone.
        </p>

        {hasBoards && (
          <div className={styles.affectedBoardsSection}>
            <p className={styles.affectedBoardsHeading}>
              Removes from {impact.boardTaskCount} board square
              {impact.boardTaskCount === 1 ? '' : 's'} on{' '}
              {impact.affectedBoards.length} board
              {impact.affectedBoards.length === 1 ? '' : 's'}:
            </p>
            <ul className={styles.affectedBoardsList}>
              {impact.affectedBoards.map((b) => {
                const expired = isBoardExpired(b);
                return (
                  <li key={b.id} className={styles.affectedBoardsItem}>
                    <span className={styles.affectedBoardsName}>
                      {b.name}
                    </span>
                    {expired ? (
                      <span
                        className={`${styles.affectedBoardsPill} ${styles.affectedBoardsPillExpired}`}
                      >
                        Expired
                      </span>
                    ) : (
                      <BoardStatusBadge status={b.status} />
                    )}
                  </li>
                );
              })}
            </ul>
          </div>
        )}

        {otherCounts > 0 && (
          <ul className={styles.impactList}>
            {impact.childLinkCount > 0 && (
              <li>
                Detaches from {impact.childLinkCount} compound parent
                {impact.childLinkCount === 1 ? '' : 's'} (the parent
                {impact.childLinkCount === 1 ? '' : 's'} loses this child).
              </li>
            )}
            {impact.parentLinkCount > 0 && (
              <li>
                Releases {impact.parentLinkCount} subtask
                {impact.parentLinkCount === 1 ? '' : 's'} (
                {impact.parentLinkCount === 1 ? 'it stays' : 'they stay'} in your
                library).
              </li>
            )}
          </ul>
        )}

        {!hasBoards && otherCounts === 0 && (
          <ul className={styles.impactList}>
            <li>No other rows affected.</li>
          </ul>
        )}

        <div className={styles.sheetActions}>
          <button
            type="button"
            className={styles.cancelButton}
            onClick={onCancel}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.deleteButton}
            onClick={onConfirm}
          >
            Delete
          </button>
        </div>
      </div>
    </div>
  );
}
