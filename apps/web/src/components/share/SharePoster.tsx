import { forwardRef } from 'react';
import styles from './SharePoster.module.css';

export interface SharePosterProps {
  boardName: string;
  completedTasks: number;
  totalTasks: number;
  linesCompleted: number;
  /**
   * Compact streak label e.g. "3d", "2w". Pass for core boards with an
   * active streak. Omit (or pass undefined) to hide the STREAK stat card.
   */
  streak?: string;
  /** Show the stat trio. Defaults to true. */
  showStats?: boolean;
}

/**
 * The shareable GREENLOG poster card — a fixed-width (280px) blue Riso card
 * with halftone overprint, a 5×5 all-done mini-grid, and an optional stat trio.
 *
 * CRITICAL: This component uses ONLY static/fixed hex colors — no adaptive
 * `var(--riso-*)` tokens. The exported PNG must be identical in light and dark
 * mode. Mirrors iOS `ShareBoardSheet.posterCard(showStats:)`.
 *
 * The halftone overprint uses a real DOM child element instead of `::after`
 * because html-to-image serialises actual DOM nodes only — pseudo-elements are
 * not captured in the foreignObject pass.
 *
 * @param boardName - Board display name (up to 2 lines on the card).
 * @param completedTasks - Number of squares completed.
 * @param totalTasks - Total squares on the board.
 * @param linesCompleted - Number of bingo lines scored.
 * @param streak - Compact streak label. Omit to hide the STREAK stat.
 * @param showStats - Whether to show the stat trio (SQUARES / BINGOS / STREAK).
 */
export const SharePoster = forwardRef<HTMLDivElement, SharePosterProps>(
  function SharePoster(
    { boardName, completedTasks, totalTasks, linesCompleted, streak, showStats = true },
    ref,
  ) {
    // iOS posterMiniGrid hardcodes 5×5 for all boards (the GREENLOG moment
    // is a full-clear so all cells are done). Mirror that here.
    const COLS = 5;
    const ROWS = 5;
    const CENTER_INDEX = Math.floor((COLS * ROWS) / 2); // 12

    return (
      <div ref={ref} className={styles.poster}>
        {/*
         * Halftone overprint — absolute DOM element (not ::after).
         * html-to-image does not serialise CSS pseudo-elements; a real child
         * is required for the dots to appear in the exported PNG.
         */}
        <div className={styles.halftone} aria-hidden="true" />

        {/* Top row: GREENLOG badge + OYBC wordmark */}
        <div className={styles.topRow}>
          <span className={styles.greenlogBadge}>GREENLOG</span>
          <span className={styles.wordmark}>OYBC</span>
        </div>

        {/* Board name — centred, up to 2 lines */}
        <div className={styles.boardName}>{boardName}</div>

        {/* 5×5 mini-grid — all done, centre cell is gold FREE */}
        <div className={styles.grid}>
          {Array.from({ length: ROWS * COLS }, (_, i) => {
            const isCenter = i === CENTER_INDEX;
            return (
              <div
                key={i}
                className={`${styles.cell} ${isCenter ? styles.cellCenter : styles.cellDone}`}
              >
                {/* Halftone overprint on done cells — same reason as outer halftone */}
                {!isCenter && <div className={styles.cellHalftone} aria-hidden="true" />}
                {/* Star glyph in FREE centre cell */}
                {isCenter && (
                  <span className={styles.star} aria-hidden="true">
                    ★
                  </span>
                )}
              </div>
            );
          })}
        </div>

        {/* Optional stat trio: SQUARES / BINGOS / STREAK */}
        {showStats && (
          <div className={styles.stats}>
            <div className={styles.statCard}>
              <span className={styles.statValue}>
                {completedTasks}/{totalTasks}
              </span>
              <span className={styles.statLabel}>SQUARES</span>
            </div>
            <div className={styles.statCard}>
              <span className={styles.statValue}>{linesCompleted}</span>
              <span className={styles.statLabel}>BINGOS</span>
            </div>
            {streak && (
              <div className={styles.statCard}>
                <span className={styles.statValue}>{streak}</span>
                <span className={styles.statLabel}>STREAK</span>
              </div>
            )}
          </div>
        )}

        {/* Footer tagline */}
        <div className={styles.footer}>OWN YOUR BINGO CARD</div>
      </div>
    );
  },
);
