import { Timeframe, formatTimeframeLabel, type Board } from '@oybc/shared';
import { isBoardExpired, getExpiryLabel } from '../utils/boardDisplayUtils';
import { BoardStatusBadge } from './BoardStatusBadge';
import styles from './BoardListItem.module.css';

interface BoardListItemProps {
  board: Board;
  onClick: () => void;
}

/**
 * BoardListItem — A single board row in the board list.
 *
 * Shows board name, timeframe label, progress bar, task count,
 * bingo count, expiry indicator, and status badge.
 */
export function BoardListItem({ board, onClick }: BoardListItemProps): React.ReactElement {
  const hasBingos = board.linesCompleted > 0;
  const progressPct =
    board.totalTasks > 0
      ? Math.round((board.completedTasks / board.totalTasks) * 100)
      : 0;
  const expired = isBoardExpired(board);

  return (
    <button
      type="button"
      className={styles.row}
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
      <BoardStatusBadge status={board.status} />
    </button>
  );
}
