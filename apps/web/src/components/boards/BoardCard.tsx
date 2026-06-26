import { BoardStatus, formatTimeframeLabel, type Board } from '@oybc/shared';
import { isBoardExpired, statusLabel } from '../../utils/boardDisplayUtils';
import { RisoBadge, type RisoBadgeKind } from '../riso';
import { BoardMiniGrid } from '../home/BoardMiniGrid';
import styles from './Boards.module.css';

export interface BoardCardProps {
  board: Board;
  onOpen: (boardId: string) => void;
}

/** Exhaustive status→badge mapping — adding a BoardStatus without a badge kind
 *  becomes a compile error here, rather than silently rendering an unstyled badge. */
const STATUS_TO_BADGE: Record<BoardStatus, RisoBadgeKind> = {
  [BoardStatus.ACTIVE]: 'active',
  [BoardStatus.COMPLETED]: 'completed',
  [BoardStatus.DRAFT]: 'draft',
  [BoardStatus.ARCHIVED]: 'archived',
};

/** Resolve the board's status badge (kind + text), flagging expired actives. */
function badgeFor(board: Board): { kind: RisoBadgeKind; text: string } {
  if (board.status === BoardStatus.ACTIVE && isBoardExpired(board)) {
    return { kind: 'expiring', text: 'Expired' };
  }
  return { kind: STATUS_TO_BADGE[board.status], text: statusLabel(board.status) };
}

/**
 * Riso board card — one card in the Boards grid: name + timeframe + status
 * badge, a progress bar + squares/bingo meta, and a board mini-grid. Reads the
 * board's denormalized fields; the mini-grid is the count-approximation
 * (`BoardMiniGrid`) — true positions would mean a live query per card.
 */
export function BoardCard({ board, onOpen }: BoardCardProps): React.ReactElement {
  const pct = board.totalTasks > 0 ? Math.round((board.completedTasks / board.totalTasks) * 100) : 0;
  const isComplete = board.status === BoardStatus.COMPLETED || board.status === BoardStatus.ARCHIVED;
  const badge = badgeFor(board);

  return (
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
  );
}
