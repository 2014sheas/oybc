import { useState } from 'react';
import { formatTimeframeLabel, type Board } from '@oybc/shared';
import { RisoIcon } from '../riso';
import styles from './Boards.module.css';

export interface ClosingOutBannerProps {
  /** Boards whose window has ended but which aren't sealed yet. */
  boards: Board[];
  /** Open the (still fully live) board to log any last activity — a tap anywhere on the row. */
  onLog: (boardId: string) => void;
  /** Seal the board — freeze its window into a permanent record. */
  onSeal: (boardId: string) => void | Promise<void>;
}

/**
 * ClosingOutBanner — Boards-tab prompt for boards whose window has closed
 * (docs/WINDOWED_COMPLETION.md §Sealing → Lifecycle → Prompt).
 *
 * Deliberately the same lazy-detection banner vocabulary as
 * `RecurringWindowBanner` (OQ3 resolution: one row per closing board, matching
 * the 6.1 recurring-window prompt). Each row: the board name + the window that
 * ended; a click anywhere on the row opens the still-live board to log (the
 * closing window keeps evaluating events until sealed), and the **Close out**
 * button seals it (freezes the snapshot via the seal transaction). The row
 * disappears once the board is sealed (the reactive `useClosingOutBoards`
 * query drops it).
 */
export function ClosingOutBanner({
  boards,
  onLog,
  onSeal,
}: ClosingOutBannerProps): React.ReactElement | null {
  const [sealingId, setSealingId] = useState<string | null>(null);
  if (boards.length === 0) return null;

  const handleSeal = async (boardId: string): Promise<void> => {
    setSealingId(boardId);
    try {
      await onSeal(boardId);
    } finally {
      setSealingId(null);
    }
  };

  return (
    <div
      className={styles.closingBanner}
      role="region"
      aria-label="Boards ready to close out"
    >
      <div className={styles.closingBannerHead}>
        <RisoIcon name="shield" size={13} aria-hidden />
        Windows closed
      </div>
      <div className={styles.closingBannerItems}>
        {boards.map((b) => {
          const sealing = sealingId === b.id;
          const open = (): void => {
            if (!sealing) onLog(b.id);
          };
          return (
            // The whole row opens the board; the name is the keyboard /
            // screen-reader handle for the same action (its click bubbles here).
            <div key={b.id} className={styles.closingBannerItem} onClick={open}>
              <div className={styles.closingBannerText}>
                <button
                  type="button"
                  className={styles.closingBannerName}
                  disabled={sealing}
                  aria-label={`Open ${b.name}`}
                >
                  {b.name}
                </button>
                <span className={styles.closingBannerWindow}>
                  Ended {formatTimeframeLabel(b.timeframe, b.startDate)} — anything left to log?
                </span>
              </div>
              <button
                type="button"
                className={styles.closingBannerSeal}
                onClick={(e) => {
                  e.stopPropagation();
                  void handleSeal(b.id);
                }}
                disabled={sealing}
                aria-label={`Close out ${b.name}`}
              >
                {sealing ? 'Closing…' : 'Close out'}
              </button>
            </div>
          );
        })}
      </div>
    </div>
  );
}
