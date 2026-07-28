import { useState } from 'react';
import { Timeframe, formatTimeframeLabel, type Board } from '@oybc/shared';
import { isBoardExpired, getExpiryLabel } from '../utils/boardDisplayUtils';
import { BoardStatusBadge } from './BoardStatusBadge';
import { RecurringBadge } from './RecurringBadge';
import styles from './BoardListItem.module.css';

interface BoardListItemProps {
  board: Board;
  onClick: () => void;
  /**
   * Called after the user confirms a delete in the confirm dialog. If
   * omitted, the trailing delete button is not rendered (e.g., for
   * read-only contexts like playground previews).
   */
  onDelete?: (boardId: string) => void | Promise<void>;
}

/**
 * BoardListItem — A single board row in the board list.
 *
 * Shows board name, timeframe label, progress bar, task count,
 * bingo count, expiry indicator, status badge, and an optional
 * trailing delete button. The row split is: outer `<div>` for layout,
 * a clickable `<button>` for the main nav target, and a separate
 * delete `<button>` next to it (nested buttons are invalid HTML).
 */
export function BoardListItem({ board, onClick, onDelete }: BoardListItemProps): React.ReactElement {
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const hasBingos = board.linesCompleted > 0;
  const progressPct =
    board.totalTasks > 0
      ? Math.round((board.completedTasks / board.totalTasks) * 100)
      : 0;
  const expired = isBoardExpired(board);

  const handleConfirm = async (): Promise<void> => {
    if (!onDelete) return;
    setDeleting(true);
    try {
      await onDelete(board.id);
    } finally {
      setDeleting(false);
      setConfirmOpen(false);
    }
  };

  return (
    <div className={styles.row}>
      <button
        type="button"
        className={styles.mainButton}
        onClick={onClick}
      >
        <div className={styles.left}>
          <span className={styles.name}>{board.name}</span>
          {board.timeframe !== Timeframe.CUSTOM && board.startDate && (
            <span className={styles.timeframeLabel}>
              {formatTimeframeLabel(board.timeframe as Timeframe, board.startDate)}
            </span>
          )}
          <div className={styles.meta}>
            <div
              className={styles.progressBar}
              role="progressbar"
              aria-valuenow={progressPct}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-label={`${progressPct}% complete`}
            >
              <div
                className={styles.progressFill}
                style={{ width: `${progressPct}%` }}
              />
            </div>
            <span className={styles.taskCount}>
              {board.completedTasks}/{board.totalTasks} tasks
            </span>
            {hasBingos && (
              <span className={styles.bingoCount}>
                {board.linesCompleted} bingo{board.linesCompleted !== 1 ? 's' : ''}
              </span>
            )}
            <span className={`${styles.expiryLabel} ${expired ? styles.expiryExpired : ''}`}>
              {getExpiryLabel(board)}
            </span>
          </div>
        </div>
        <div className={styles.badges}>
          {board.spawnedFromTemplateId != null && <RecurringBadge />}
          <BoardStatusBadge status={board.status} />
        </div>
      </button>

      {onDelete && (
        <button
          type="button"
          className={styles.deleteButton}
          onClick={() => setConfirmOpen(true)}
          aria-label={`Delete ${board.name}`}
          title="Delete board"
        >
          ✕
        </button>
      )}

      {confirmOpen && (
        <div
          className={styles.confirmBackdrop}
          onClick={() => !deleting && setConfirmOpen(false)}
        >
          <div
            className={styles.confirmDialog}
            role="alertdialog"
            aria-label="Confirm delete board"
            onClick={(e) => e.stopPropagation()}
          >
            <h2 className={styles.confirmHeading}>Delete board?</h2>
            <p className={styles.confirmBody}>
              “{board.name}” will be removed. This can’t be undone from the
              app, though it remains recoverable from Firestore if needed.
            </p>
            <div className={styles.confirmActions}>
              <button
                type="button"
                className={styles.confirmCancel}
                onClick={() => setConfirmOpen(false)}
                disabled={deleting}
              >
                Cancel
              </button>
              <button
                type="button"
                className={styles.confirmDelete}
                onClick={handleConfirm}
                disabled={deleting}
              >
                {deleting ? 'Deleting…' : 'Delete'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
