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
 * Counters P3; copy tightened in Counters Refresh R3).
 *
 * Shown on board-open when ≥1 shared-counter square filled in from a log
 * made elsewhere (Counter Detail / another board).
 *
 * Copy contract (pinned byte-exact, R3 board-play touchpoints):
 *   single:   "{task name} filled in — you logged {counter name} elsewhere.
 *              See every board ›"
 *   multiple: "{N} squares filled in from your counters. Open counters ›"
 *
 * `taskName` is the SQUARE/task's own name (stays title-first — unaffected
 * by R3); `counterName` is pair-derived (`formatCounterName`, stored-title
 * fallback) per the R3 copy contract's counter-name rule — resolved by the
 * caller (`useCounterArrivals`'s `counterDisplayName`).
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
            <em>{taskName}</em> filled in — you logged {counterName} elsewhere.{' '}
            <span className={styles.arrivalCta}>See every board ›</span>
          </>
        ) : (
          <>
            <strong>{squareCount} squares</strong> filled in from your counters.{' '}
            <span className={styles.arrivalCta}>Open counters ›</span>
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
