import styles from './Play.module.css';

export interface RisoArrivalBannerProps {
  /** Total arrived squares — selects the single-vs-multiple copy. */
  squareCount: number;
  /** The arrived square's task name (single-square variant only). */
  taskName?: string;
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
 *   single:   "{task name} filled in · See every board ›"
 *   multiple: "{N} squares filled in · Open counters ›"
 *
 * `taskName` is the SQUARE/task's own name (stays title-first). No
 * provenance clause ("you logged X elsewhere") — #548.
 *
 * Riso gold surface with `--riso-ink-static` content (adaptive `--riso-ink`
 * would vanish on the light gold fill in dark mode — see
 * reference_riso_adaptive_ink_fill_darkmode).
 */
export function RisoArrivalBanner({
  squareCount,
  taskName,
  onOpen,
  onDismiss,
}: RisoArrivalBannerProps): React.ReactElement {
  const isSingle = squareCount === 1 && !!taskName;

  return (
    <div className={styles.arrival} role="status" aria-live="polite">
      <span className={styles.arrivalDot} aria-hidden="true">↔</span>
      <button type="button" className={styles.arrivalBody} onClick={onOpen}>
        {isSingle ? (
          <>
            <em>{taskName}</em> filled in ·{' '}
            <span className={styles.arrivalCta}>See every board ›</span>
          </>
        ) : (
          <>
            <strong>{squareCount} squares</strong> filled in ·{' '}
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
