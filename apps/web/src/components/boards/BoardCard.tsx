import { useState } from 'react';
import { BoardStatus, formatTimeframeLabel, type Board } from '@oybc/shared';
import { isBoardExpired, isBoardExpiringSoon, statusLabel } from '../../utils/boardDisplayUtils';
import { RisoBadge, RisoIcon, type RisoBadgeKind } from '../riso';
import { BoardMiniGrid } from '../home/BoardMiniGrid';
import styles from './Boards.module.css';

export interface BoardCardProps {
  board: Board;
  onOpen: (boardId: string) => void;
  /**
   * Called after the user confirms deletion. When omitted the delete
   * affordance is not rendered (e.g., read-only contexts).
   */
  onDelete?: (boardId: string) => void | Promise<void>;
}

/** Exhaustive status→badge mapping — adding a BoardStatus without a badge kind
 *  becomes a compile error here, rather than silently rendering an unstyled badge. */
const STATUS_TO_BADGE: Record<BoardStatus, RisoBadgeKind> = {
  [BoardStatus.ACTIVE]: 'active',
  [BoardStatus.COMPLETED]: 'completed',
  [BoardStatus.DRAFT]: 'draft',
  [BoardStatus.ARCHIVED]: 'archived',
};

/**
 * Resolve the board's status badge (kind + text).
 *
 * Priority order (mirrors iOS `RisoBoardCard` badge logic):
 *   1. Active + past end date      → "Expired"      (gold)
 *   2. Active + within 24 h       → "Expiring soon" (gold)
 *   3. Everything else            → normal status badge
 */
function badgeFor(board: Board): { kind: RisoBadgeKind; text: string } {
  if (board.status === BoardStatus.ACTIVE && isBoardExpired(board)) {
    return { kind: 'expiring', text: 'Expired' };
  }
  if (isBoardExpiringSoon(board)) {
    return { kind: 'expiring', text: 'Expiring soon' };
  }
  return { kind: STATUS_TO_BADGE[board.status], text: statusLabel(board.status) };
}

/**
 * Riso board card — one card in the Boards grid: name + timeframe + status
 * badge, a progress bar + squares/bingo meta, and a board mini-grid. Reads the
 * board's denormalized fields; the mini-grid is the count-approximation
 * (`BoardMiniGrid`) — true positions would mean a live query per card.
 *
 * When `onDelete` is provided a hover-revealed trash button appears; confirming
 * it opens a Riso-styled alert dialog before committing the soft-delete.
 */
export function BoardCard({ board, onOpen, onDelete }: BoardCardProps): React.ReactElement {
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);

  const pct = board.totalTasks > 0 ? Math.round((board.completedTasks / board.totalTasks) * 100) : 0;
  const isComplete = board.status === BoardStatus.COMPLETED || board.status === BoardStatus.ARCHIVED;
  const badge = badgeFor(board);

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
    <div className={styles.bcardWrap}>
      <button type="button" className={styles.bcard} onClick={() => onOpen(board.id)}>
        <div className={styles.bcardTop}>
          <div>
            <div className={styles.bcardName}>{board.name}</div>
            <div className={styles.bcardTf}>{formatTimeframeLabel(board.timeframe, board.startDate)}</div>
          </div>
          <RisoBadge kind={badge.kind}>{badge.text}</RisoBadge>
        </div>
        <div className={styles.bcardBody}>
          <div className={styles.bcardL}>
            <div className={`${styles.progress} ${isComplete ? styles.progressGreen : ''}`}>
              <div className={styles.progressFill} style={{ width: `${pct}%` }} />
            </div>
            <div className={styles.bcardMeta}>
              <span>
                {board.completedTasks}/{board.totalTasks} squares
              </span>
              {board.linesCompleted > 0 && (
                <span className={styles.bingo}>
                  <span className={styles.star}>★</span>
                  {board.linesCompleted} bingo{board.linesCompleted === 1 ? '' : 's'}
                </span>
              )}
            </div>
          </div>
          <BoardMiniGrid board={board} cell={11} />
        </div>
      </button>

      {onDelete && (
        <button
          type="button"
          className={styles.bcardDeleteBtn}
          onClick={() => setConfirmOpen(true)}
          aria-label={`Delete ${board.name}`}
          title="Delete board"
        >
          <RisoIcon name="trash" size={13} />
        </button>
      )}

      {confirmOpen && (
        <div
          className={styles.bcardConfirmBackdrop}
          onClick={() => !deleting && setConfirmOpen(false)}
        >
          <div
            className={styles.bcardConfirmDialog}
            role="alertdialog"
            aria-label="Confirm delete board"
            onClick={(e) => e.stopPropagation()}
          >
            <h2 className={styles.bcardConfirmHeading}>Delete board?</h2>
            <p className={styles.bcardConfirmBody}>
              "{board.name}" will be removed. This can't be undone from the app.
            </p>
            <div className={styles.bcardConfirmActions}>
              <button
                type="button"
                className={styles.bcardConfirmCancel}
                onClick={() => setConfirmOpen(false)}
                disabled={deleting}
              >
                Cancel
              </button>
              <button
                type="button"
                className={styles.bcardConfirmDelete}
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
