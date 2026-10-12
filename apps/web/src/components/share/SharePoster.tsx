import { forwardRef } from 'react';
import type { PosterCell } from '@oybc/shared';
import { POSTER_GAP_PX, posterBadge, posterCellPx, posterLabelSize, type ShareKind } from './sharePosterModel';
import styles from './SharePoster.module.css';

export interface SharePosterProps {
  kind: ShareKind;
  boardName: string;
  boardSize: number;
  /** End-state cells (`momentPosterCells`), row-major. */
  cells: PosterCell[];
  completedTasks: number;
  totalTasks: number;
  /** Compact streak label ("2w"). Omit to hide the STREAK card (the SQUARES card then spans the row). */
  streak?: string;
  /** Draw each cell's task name. */
  showLabels: boolean;
}

/**
 * The shareable story poster (9:16, 236 x 420 at preview, exported at 2x): the
 * moment's end-state board over a blue (bingo) or green (greenlog) Riso card
 * with halftone overprint, a SQUARES card and, on a recurring board with a
 * streak above 1, a STREAK card.
 *
 * CRITICAL: static hex colours only - no adaptive `var(--riso-*)` tokens. The
 * exported PNG must be identical in light and dark mode. Halftones are real DOM
 * children because html-to-image does not serialise pseudo-elements.
 */
export const SharePoster = forwardRef<HTMLDivElement, SharePosterProps>(
  function SharePoster({ kind, boardName, boardSize, cells, completedTasks, totalTasks, streak, showLabels }, ref) {
    const labelPx = posterLabelSize(posterCellPx(boardSize));
    return (
      <div ref={ref} className={`${styles.poster} ${kind === 'bingo' ? styles.bingo : styles.greenlog}`} data-kind={kind}>
        <div className={styles.halftone} aria-hidden="true" />

        <div className={styles.topRow}>
          <span className={styles.badge}>{posterBadge(kind)}</span>
          <span className={styles.wordmark}>OYBC</span>
        </div>

        <div className={styles.boardName}>{boardName}</div>

        <div className={styles.gridInset}>
          <div
            className={styles.grid}
            data-testid="poster-grid"
            style={{
              gridTemplateColumns: `repeat(${boardSize}, minmax(0, 1fr))`,
              gridTemplateRows: `repeat(${boardSize}, minmax(0, 1fr))`,
              gap: POSTER_GAP_PX,
            }}
          >
            {cells.map((c) => {
              const tone = c.isFree ? (c.state === 'green' ? 'green' : 'free') : c.state === 'undone' ? 'undone' : c.state === 'green' ? 'green' : c.type;
              const filled = !c.isFree && c.state !== 'undone';
              return (
                <div key={c.idx} className={`${styles.cell} ${styles[tone] ?? ''}`} data-state={c.state} data-free={c.isFree || undefined}>
                  {(filled || (c.isFree && c.state === 'green')) && <div className={styles.cellHalftone} aria-hidden="true" />}
                  {c.isFree ? (
                    <span className={styles.star} aria-hidden="true">★</span>
                  ) : (
                    showLabels && c.label && <span className={styles.label} style={{ fontSize: labelPx }}>{c.label}</span>
                  )}
                </div>
              );
            })}
          </div>
        </div>

        <div className={styles.stats}>
          <div className={styles.statCard}>
            <span className={styles.statValue}>{completedTasks}/{totalTasks}</span>
            <span className={styles.statLabel}>SQUARES</span>
          </div>
          {streak && (
            <div className={styles.statCard}>
              <span className={styles.statValue}>{streak}</span>
              <span className={styles.statLabel}>STREAK</span>
            </div>
          )}
        </div>

        <div className={styles.footer}>What&apos;s on your bingo card</div>
      </div>
    );
  },
);
