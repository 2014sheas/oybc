import type { PendingRecurringBoard } from '@oybc/shared';
import { RisoIcon } from '../riso';
import styles from './Boards.module.css';

export interface RecurringWindowBannerProps {
  /** Pending recurring windows the user should be prompted to create a board for. */
  pending: PendingRecurringBoard[];
  /**
   * Called when the user taps the CTA for a pending window.
   * Parent navigates to the wizard prefilled for that timeframe + window.
   * Never creates a board itself — this is a lazy-detection-only banner
   * (CLAUDE.md §Recurring Boards invariant: no board is ever created
   *  or written to the DB without a user action).
   */
  onSetUp: (pending: PendingRecurringBoard) => void;
}

/**
 * RecurringWindowBanner — Boards-tab banner surfacing recurring windows
 * that have opened but don't have a board yet.
 *
 * Mirrors iOS Phase 6.1's recurring-window prompt. Rendered on the
 * Boards screen when `usePendingRecurringBoards` returns a non-empty
 * array. Disappears automatically once the user creates the board
 * (the hook reacts to Dexie changes).
 *
 * Each item is a tappable card that calls `onSetUp` — the parent
 * navigates to `/create?recurringTimeframe=…&windowDate=…` so the
 * wizard opens prefilled for that window.
 */
export function RecurringWindowBanner({
  pending,
  onSetUp,
}: RecurringWindowBannerProps): React.ReactElement | null {
  if (pending.length === 0) return null;

  return (
    <div
      className={styles.recurringBanner}
      role="region"
      aria-label="New recurring windows to set up"
    >
      <div className={styles.recurringBannerHead}>
        <RisoIcon name="repeat" size={13} aria-hidden />
        New windows
      </div>
      <div className={styles.recurringBannerItems}>
        {pending.map((p) => (
          <button
            key={p.timeframe}
            type="button"
            className={styles.recurringBannerItem}
            onClick={() => onSetUp(p)}
          >
            <span className={styles.recurringBannerLabel}>{p.suggestedName}</span>
            <span className={styles.recurringBannerCta} aria-hidden>
              Set up →
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}
