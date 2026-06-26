import styles from './Play.module.css';

export interface RisoBingoToastProps {
  /** Total bingo lines on the board (shown as the big count). */
  count: number;
}

/**
 * Blue bingo toast — drops in from the top when a new bingo line forms.
 * The parent owns visibility + auto-dismiss; this is presentational. Keyed by
 * the parent so re-firing replays the drop animation.
 */
export function RisoBingoToast({ count }: RisoBingoToastProps): React.ReactElement {
  return (
    <div className={styles.toast} role="status" aria-live="polite">
      <div className={styles.toastArt} aria-hidden="true">
        ★
      </div>
      <div>
        <div className={styles.toastH}>BINGO!</div>
        <div className={styles.toastS}>Line complete — keep the press running.</div>
      </div>
      <div className={styles.toastCnt}>{count}</div>
    </div>
  );
}
