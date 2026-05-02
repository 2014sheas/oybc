import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Timeframe, type PendingRecurringBoard } from '@oybc/shared';
import styles from './RecurringBoardsBanner.module.css';

const TIMEFRAME_DISPLAY: Record<
  Timeframe,
  { icon: string; label: string }
> = {
  [Timeframe.YEARLY]: { icon: '🎯', label: 'Yearly' },
  [Timeframe.MONTHLY]: { icon: '📆', label: 'Monthly' },
  [Timeframe.WEEKLY]: { icon: '🗓', label: 'Weekly' },
  [Timeframe.DAILY]: { icon: '📅', label: 'Daily' },
  [Timeframe.CUSTOM]: { icon: '📌', label: 'Custom' }, // never reached in Phase 1
};

export interface RecurringBoardsBannerProps {
  pending: PendingRecurringBoard[];
}

/**
 * RecurringBoardsBanner — Lists the recurring board windows the user
 * should be prompted to create. Rendered above the board list on the
 * Boards tab when `pending.length > 0`.
 *
 * Two affordances per row:
 *   - **Create**: navigates to `/create?recurringTimeframe=<t>`. The
 *     CreateHubPage detects the param on mount and enters wizard mode
 *     with the timeframe prefilled (and the field locked).
 *   - **Dismiss**: hides that row for the **rest of the app session**
 *     (no persistence). Re-prompts on next launch. Permanent suppression
 *     is via the corresponding toggle in Board Preferences.
 *
 * Order of pending entries is preserved from `findPendingRecurringBoards`
 * (longest-window-first) so creating top-down builds the parent chain
 * before children — this makes the wizard's "From parent boards" filter
 * useful immediately.
 */
export function RecurringBoardsBanner({
  pending,
}: RecurringBoardsBannerProps): React.ReactElement | null {
  const navigate = useNavigate();
  const [dismissedKeys, setDismissedKeys] = useState<Set<string>>(new Set());

  const visible = useMemo(
    () =>
      pending.filter(
        (p) => !dismissedKeys.has(`${p.timeframe}::${p.startDate}`)
      ),
    [pending, dismissedKeys]
  );

  if (visible.length === 0) return null;

  function handleCreate(entry: PendingRecurringBoard): void {
    navigate(`/create?recurringTimeframe=${entry.timeframe}`);
  }

  function handleDismiss(entry: PendingRecurringBoard): void {
    setDismissedKeys((prev) => {
      const next = new Set(prev);
      next.add(`${entry.timeframe}::${entry.startDate}`);
      return next;
    });
  }

  return (
    <section
      className={styles.banner}
      aria-label="Recurring boards to create"
    >
      <h2 className={styles.heading}>Pending recurring boards</h2>
      {visible.map((entry) => {
        const display = TIMEFRAME_DISPLAY[entry.timeframe];
        const key = `${entry.timeframe}::${entry.startDate}`;
        return (
          <div key={key} className={styles.row}>
            <span className={styles.icon} aria-hidden="true">
              {display.icon}
            </span>
            <div className={styles.label}>
              <span className={styles.timeframeLabel}>{display.label}</span>
              <span className={styles.windowLabel}>{entry.suggestedName}</span>
            </div>
            <div className={styles.actions}>
              <button
                type="button"
                className={styles.createButton}
                onClick={() => handleCreate(entry)}
              >
                Create
              </button>
              <button
                type="button"
                className={styles.dismissButton}
                onClick={() => handleDismiss(entry)}
                aria-label={`Dismiss ${display.label} prompt for this session`}
              >
                Dismiss
              </button>
            </div>
          </div>
        );
      })}
    </section>
  );
}
