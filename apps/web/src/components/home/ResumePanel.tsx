import { formatTimeframeLabel, Timeframe, type Board } from '@oybc/shared';
import { getExpiryLabel } from '../../utils/boardDisplayUtils';
import { RisoButton, RisoIcon } from '../riso';
import { RisoBoard } from '../board/RisoBoard';
import styles from './Home.module.css';

/** Status-dot color by timeframe (matches the prototype's dotColor map). */
const DOT_COLOR: Record<string, string> = {
  [Timeframe.DAILY]: 'var(--riso-blue)',
  [Timeframe.WEEKLY]: 'var(--riso-green)',
  [Timeframe.MONTHLY]: 'var(--riso-gold)',
  [Timeframe.YEARLY]: 'var(--riso-green)',
  [Timeframe.CUSTOM]: 'var(--riso-muted)',
  [Timeframe.INDEFINITE]: 'var(--riso-muted)',
};

export interface ResumePanelProps {
  board: Board;
  onOpen: (boardId: string) => void;
}

/**
 * "Jump back in" resume panel — the featured (most-recently-active) board:
 * timeframe tag + name + squares/bingo meta + progress, Resume / Board details
 * CTAs, and a decorative board mini-grid poster. All from the board's
 * denormalized fields (no task query).
 */
export function ResumePanel({ board, onOpen }: ResumePanelProps): React.ReactElement {
  const pct = board.totalTasks > 0 ? Math.round((board.completedTasks / board.totalTasks) * 100) : 0;
  const bingos = board.linesCompleted;
  // INDEFINITE boards never expire — "Ongoing" already says it, so skip the
  // "No deadline" expiry label getExpiryLabel would otherwise return.
  const expiry = board.timeframe === Timeframe.INDEFINITE ? '' : getExpiryLabel(board);
  const tag = [formatTimeframeLabel(board.timeframe, board.startDate), expiry].filter(Boolean).join(' · ');

  return (
    <div className={styles.resume}>
      <div>
        <span className={styles.resumeTag}>
          <span className={styles.boardDot} style={{ background: DOT_COLOR[board.timeframe] ?? 'var(--riso-muted)' }} />
          {tag}
        </span>
        <h2 className={styles.resumeName}>{board.name}</h2>
        <div className={styles.resumeMeta}>
          <span>
            {board.completedTasks}/{board.totalTasks} squares
          </span>
          {bingos > 0 && (
            <span className={styles.bingo}>
              <span className={styles.star}>★</span>
              {bingos} bingo{bingos === 1 ? '' : 's'}
            </span>
          )}
        </div>
        <div className={styles.progress}>
          <div className={styles.progressFill} style={{ width: `${pct}%` }} />
        </div>
        <div className={styles.resumeCta}>
          {/* Single CTA: web has no separate board-details surface — the play
              page is both. (The prototype's second "Board details" button went
              to the same place; a redundant affordance, so it's omitted.) */}
          <RisoButton
            kind="primary"
            size="large"
            icon={<RisoIcon name="boards" size={16} />}
            onClick={() => onOpen(board.id)}
          >
            Resume board
          </RisoButton>
        </div>
      </div>
      <button
        type="button"
        className={styles.posterButton}
        onClick={() => onOpen(board.id)}
        aria-label={`Open ${board.name}`}
      >
        {/* Real type/done-aware poster (Phase 3a renderer) — true cell positions. */}
        <RisoBoard board={board} cellSize={58} />
      </button>
    </div>
  );
}
