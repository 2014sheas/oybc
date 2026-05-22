import styles from './CoreBoardBrowserPage.module.css';

export interface CoreBoardWindowBarProps {
  /** e.g. "Today", "Week of May 18 – 24, 2026". */
  label: string;
  onPrev: () => void;
  onNext: () => void;
  /** Opens the full vertical window browser for this timeframe. */
  onOpenList: () => void;
}

/**
 * CoreBoardWindowBar — top chrome for the per-window core-board pager:
 * ‹ prev · window label · next ›, plus a list button that opens the full
 * browser. Prev/next are always enabled (paging is unbounded both ways).
 */
export function CoreBoardWindowBar({
  label,
  onPrev,
  onNext,
  onOpenList,
}: CoreBoardWindowBarProps): React.ReactElement {
  return (
    <div className={styles.windowBar}>
      <button
        type="button"
        className={styles.windowNav}
        onClick={onPrev}
        aria-label="Previous window"
      >
        ‹
      </button>
      <span className={styles.windowBarLabel}>{label}</span>
      <button
        type="button"
        className={styles.windowNav}
        onClick={onNext}
        aria-label="Next window"
      >
        ›
      </button>
      <button
        type="button"
        className={styles.windowListButton}
        onClick={onOpenList}
        aria-label="Show all windows"
      >
        ≡ List
      </button>
    </div>
  );
}
