import type { WindowNeighborhoodDot } from './corePickerTiles';
import styles from './CoreWindow.module.css';

export interface CoreWindowPositionCaptionProps {
  /** Previous window's label ("August"). */
  prevLabel: string;
  /** Next window's label ("October"). */
  nextLabel: string;
  /** ±2-window position dots (from `buildWindowNeighborhood`). */
  dots: WindowNeighborhoodDot[];
  /** Stepping is disabled (edit mode). */
  disabled?: boolean;
  onPrev: () => void;
  onNext: () => void;
}

/**
 * CoreWindowPositionCaption — the centred `‹ August · dots · October ›`
 * row under the board grid. Tapping a side steps one window (same as the
 * swipe / arrow keys). Mirrors iOS `CoreWindowPositionCaption`.
 */
export function CoreWindowPositionCaption({
  prevLabel,
  nextLabel,
  dots,
  disabled = false,
  onPrev,
  onNext,
}: CoreWindowPositionCaptionProps): React.ReactElement {
  return (
    <div className={styles.caption}>
      <button
        type="button"
        className={styles.captionSide}
        onClick={onPrev}
        disabled={disabled}
        aria-label="Previous window"
      >
        ‹ {prevLabel}
      </button>
      <span className={styles.captionDots} aria-hidden="true">
        {dots.map((d) => {
          const cls = [
            styles.dot,
            d.isDisplayed ? styles.dotDisplayed : '',
            !d.hasBoard ? (d.isDisplayed ? styles.dotDisplayedEmpty : styles.dotEmpty) : '',
            d.isToday ? styles.dotToday : '',
          ]
            .filter(Boolean)
            .join(' ');
          return <i key={d.offset} className={cls} />;
        })}
      </span>
      <button
        type="button"
        className={styles.captionSide}
        onClick={onNext}
        disabled={disabled}
        aria-label="Next window"
      >
        {nextLabel} ›
      </button>
    </div>
  );
}
