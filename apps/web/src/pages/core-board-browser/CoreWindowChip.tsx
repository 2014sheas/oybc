import type { WindowNeighborhoodDot } from './corePickerTiles';
import styles from './CoreWindow.module.css';

export interface CoreWindowChipProps {
  /** Window label + suffix, e.g. "September 2026" / "October · next". */
  label: string;
  /** ±2-window position dots (from `buildWindowNeighborhood`). */
  dots: WindowNeighborhoodDot[];
  /** Picker is open — chip inverts to ink fill, chevron flips up. */
  open: boolean;
  /** Displayed window has no board — dashed keyline, no shadow. */
  empty: boolean;
  /** Edit mode — dimmed to 45%, non-interactive. */
  disabled?: boolean;
  /** Accessibility label ("September, current window. Opens window picker."). */
  ariaLabel: string;
  onClick: () => void;
}

/** One position dot. */
function Dot({ dot }: { dot: WindowNeighborhoodDot }): React.ReactElement {
  const cls = [
    styles.dot,
    dot.isDisplayed ? styles.dotDisplayed : '',
    !dot.hasBoard ? (dot.isDisplayed ? styles.dotDisplayedEmpty : styles.dotEmpty) : '',
    dot.isToday ? styles.dotToday : '',
  ]
    .filter(Boolean)
    .join(' ');
  return <i className={cls} aria-hidden="true" />;
}

/**
 * CoreWindowChip — the pager's window chip: position dots + window label
 * + a chevron. Tapping opens the window picker popover. Mirrors the iOS
 * `CoreWindowChipView`.
 */
export function CoreWindowChip({
  label,
  dots,
  open,
  empty,
  disabled = false,
  ariaLabel,
  onClick,
}: CoreWindowChipProps): React.ReactElement {
  const className = [
    styles.chip,
    open ? styles.chipOpen : '',
    empty && !open ? styles.chipEmpty : '',
    disabled ? styles.chipDisabled : '',
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <button
      type="button"
      className={className}
      onClick={onClick}
      disabled={disabled}
      aria-label={ariaLabel}
      aria-expanded={open}
      aria-haspopup="dialog"
    >
      <span className={styles.chipDots}>
        {dots.map((d) => (
          <Dot key={d.offset} dot={d} />
        ))}
      </span>
      {label}
      <span className={styles.chipChevron} aria-hidden="true">
        <svg
          width="10"
          height="10"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="3"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          {open ? <polyline points="18 15 12 9 6 15" /> : <polyline points="6 9 12 15 18 9" />}
        </svg>
      </span>
    </button>
  );
}
