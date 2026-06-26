import { BoardStatus, Timeframe, type CoreBoardSlot } from '@oybc/shared';
import { isBoardExpired } from '../../utils/boardDisplayUtils';
import styles from './Boards.module.css';

const TF_LABEL: Partial<Record<Timeframe, string>> = {
  [Timeframe.DAILY]: 'Daily',
  [Timeframe.WEEKLY]: 'Weekly',
  [Timeframe.MONTHLY]: 'Monthly',
  [Timeframe.YEARLY]: 'Yearly',
};

export interface CoreStripProps {
  slots: CoreBoardSlot[];
  onSelect: (slot: CoreBoardSlot) => void;
}

/** Status line + dot for a slot's current-window board. */
function slotStatus(slot: CoreBoardSlot): { text: string; dot: string } {
  const b = slot.currentBoard;
  if (!b) return { text: 'Set up', dot: '' };
  if (b.status === BoardStatus.COMPLETED) return { text: 'Cleared', dot: styles.green };
  if (b.status === BoardStatus.DRAFT) return { text: 'Resume draft', dot: styles.warn };
  if (b.status === BoardStatus.ACTIVE && isBoardExpired(b)) return { text: 'Expired', dot: styles.warn };
  return { text: `${b.completedTasks}/${b.totalTasks}`, dot: styles.blue };
}

/**
 * Core-timeframe strip — one card per enabled recurring timeframe
 * (Daily/Weekly/Monthly/Yearly), each showing the current window's status + a
 * colored dot. Whole-card tap → the per-timeframe window pager (parent decides).
 */
export function CoreStrip({ slots, onSelect }: CoreStripProps): React.ReactElement | null {
  if (slots.length === 0) return null;
  return (
    <div className={styles.coreStrip}>
      {slots.map((slot) => {
        const status = slotStatus(slot);
        return (
          <button key={slot.timeframe} type="button" className={styles.coreCard} onClick={() => onSelect(slot)}>
            <div className={styles.coreK}>{TF_LABEL[slot.timeframe] ?? slot.timeframe}</div>
            <div className={styles.coreV}>
              <span className={`${styles.coreDot} ${status.dot}`} />
              {status.text}
            </div>
          </button>
        );
      })}
    </div>
  );
}
