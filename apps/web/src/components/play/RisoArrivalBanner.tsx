import styles from './Play.module.css';

export interface RisoArrivalBannerProps {
  /** Total arrived squares — selects the single-vs-multiple copy. */
  squareCount: number;
  /** The arrived square's task name (single-square variant only). */
  taskName?: string;
  /** The arrived counter's display name (single-square variant only). */
  counterName?: string;
  /** Tap the banner body → open Counter Detail (single counter) / the Hub. */
  onOpen: () => void;
  /** ✕ dismiss. */
  onDismiss: () => void;
}

/**
 * Gold arrival banner — the passive-completion "signature moment" (Shared
 * Counters P3). Shown on board-open when ≥1 shared-counter square filled in
 * from a log made elsewhere (Counter Detail / another board).
 *
 * Copy contract (verbatim, docs/SHARED_COUNTERS.md §P3):
 *   single:   "*{task name}* filled in here from your {counter name} counter
 *              — logged on another board · See every board it counts on ›"
 *   multiple: "**N squares** filled in from your counters — logged on other
 *              boards."
 *
 * Riso gold surface with `--riso-ink-static` content (adaptive `--riso-ink`
 * would vanish on the light gold fill in dark mode — see
 * reference_riso_adaptive_ink_fill_darkmode).
 */
export function RisoArrivalBanner({
  squareCount,
  taskName,
  counterName,
  onOpen,
  onDismiss,
}: RisoArrivalBannerProps): React.ReactElement {
  const isSingle = squareCount === 1 && !!taskName && !!counterName;

  return (
    <div className={styles.arrival} role="status" aria-live="polite">
      <span className={styles.arrivalDot} aria-hidden="true">↔</span>
      <button type="button" className={styles.arrivalBody} onClick={onOpen}>
        {isSingle ? (
          <>
            <em>{taskName}</em> filled in here from your {counterName} counter — logged on
            another board <span className={styles.arrivalCta}>· See every board it counts on ›</span>
          </>
        ) : (
          <>
            <strong>{squareCount} squares</strong> filled in from your counters — logged on other
            boards.
          </>
        )}
      </button>
      <button
        type="button"
        className={styles.arrivalClose}
        onClick={onDismiss}
        aria-label="Dismiss"
      >
        ✕
      </button>
    </div>
  );
}
