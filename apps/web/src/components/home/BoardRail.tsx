import { formatTimeframeLabel, type Board } from '@oybc/shared';
import { BoardMiniGrid } from './BoardMiniGrid';
import styles from './Home.module.css';

export interface BoardRailProps {
  boards: Board[];
  onOpen: (boardId: string) => void;
}

/**
 * "Your other active boards" rail — up to four compact cards, each a mini-grid
 * + name + timeframe + progress + bingo count. Built from the boards'
 * denormalized fields.
 */
export function BoardRail({ boards, onOpen }: BoardRailProps): React.ReactElement {
  return (
    <div className={styles.rail}>
      {boards.map((b) => {
        const pct = b.totalTasks > 0 ? Math.round((b.completedTasks / b.totalTasks) * 100) : 0;
        return (
          <button key={b.id} type="button" className={styles.railCard} onClick={() => onOpen(b.id)}>
            <div className={styles.railTop}>
              <BoardMiniGrid board={b} cell={9} />
              <div>
                <div className={styles.railName}>{b.name}</div>
                <div className={styles.railTf}>{formatTimeframeLabel(b.timeframe, b.startDate)}</div>
              </div>
            </div>
            <div className={`${styles.progress} ${styles.railProgress}`}>
              <div className={styles.progressFill} style={{ width: `${pct}%` }} />
            </div>
            <div className={styles.railFoot}>
              <span>
                {b.completedTasks}/{b.totalTasks}
              </span>
              <span>
                {b.linesCompleted} bingo{b.linesCompleted === 1 ? '' : 's'}
              </span>
            </div>
          </button>
        );
      })}
    </div>
  );
}
