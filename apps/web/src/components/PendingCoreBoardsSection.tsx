import { useMemo, useState } from 'react';
import { Timeframe, type PendingRecurringBoard } from '@oybc/shared';
import styles from './PendingCoreBoardsSection.module.css';

const TIMEFRAME_DISPLAY: Record<Timeframe, { icon: string; label: string }> = {
  [Timeframe.YEARLY]: { icon: '🎯', label: 'Yearly' },
  [Timeframe.MONTHLY]: { icon: '📆', label: 'Monthly' },
  [Timeframe.WEEKLY]: { icon: '🗓', label: 'Weekly' },
  [Timeframe.DAILY]: { icon: '📅', label: 'Daily' },
  [Timeframe.CUSTOM]: { icon: '📌', label: 'Custom' }, // never reached in Phase 1
};

export type PendingCoreBoardsSectionVariant = 'boards-tab' | 'create-tab';

export interface PendingCoreBoardsSectionProps {
  /** Output of `usePendingRecurringBoards(userId)`. Pre-sorted longest-first. */
  pending: PendingRecurringBoard[];
  /** Which surface this section is mounted on. Drives heading copy + spacing.
   *  - `boards-tab`: above the board list. Heading "Pending boards".
   *  - `create-tab`: above the custom-board CTA. Heading "Get started with today's boards". */
  variant: PendingCoreBoardsSectionVariant;
  /** Invoked when the user taps Create on a row. Parent decides what to do —
   *  the Boards-tab consumer navigates via URL param (cross-tab handoff); the
   *  Create-tab consumer flips its internal mode directly. Hoisting the
   *  behavior here lets the create-tab path skip a useless URL round-trip. */
  onCreate: (entry: PendingRecurringBoard) => void;
  /** Optional — invoked when the user taps the secondary "Browse →"
   *  link on a card. Opens the per-timeframe core-board browser so the
   *  user can plan future windows or revisit past ones. Omit on the
   *  Create-tab variant (no browser entry point from there). */
  onBrowse?: (entry: PendingRecurringBoard) => void;
}

/**
 * PendingCoreBoardsSection — Promotes the "core boards" (daily / weekly /
 * monthly / yearly recurring boards) to the headline action on the Boards
 * and Create tabs. Replaces the smaller `RecurringBoardsBanner` from the
 * earlier 6.1b implementation.
 *
 * Each pending entry renders as a tappable card (large icon + bold timeframe
 * label + suggested-name subtitle + prominent Create button + secondary
 * Dismiss link). Renders nothing when `pending` is empty — the parent's
 * fallback content (custom-board CTA on Create, plain board list on Boards)
 * takes over.
 *
 * Dismissals are session-only via local `Set<string>` state. Permanent
 * suppression is the per-timeframe toggle in Board Preferences.
 */
export function PendingCoreBoardsSection({
  pending,
  variant,
  onCreate,
  onBrowse,
}: PendingCoreBoardsSectionProps): React.ReactElement | null {
  const [dismissedKeys, setDismissedKeys] = useState<Set<string>>(new Set());

  const visible = useMemo(
    () =>
      pending.filter(
        (p) => !dismissedKeys.has(`${p.timeframe}::${p.startDate}`)
      ),
    [pending, dismissedKeys]
  );

  if (visible.length === 0) return null;

  function handleDismiss(entry: PendingRecurringBoard): void {
    setDismissedKeys((prev) => {
      const next = new Set(prev);
      next.add(`${entry.timeframe}::${entry.startDate}`);
      return next;
    });
  }

  const heading =
    variant === 'create-tab' ? "Get started with today's boards" : 'Pending boards';

  return (
    <section
      className={styles.section}
      aria-label="Recurring boards to create"
    >
      <h2 className={styles.heading}>{heading}</h2>
      <div className={styles.cards}>
        {visible.map((entry) => {
          const display = TIMEFRAME_DISPLAY[entry.timeframe];
          const key = `${entry.timeframe}::${entry.startDate}`;
          return (
            <div key={key} className={styles.card}>
              <div className={styles.icon} aria-hidden="true">
                {display.icon}
              </div>
              <div className={styles.label}>
                <span className={styles.timeframeLabel}>{display.label}</span>
                <span className={styles.windowLabel}>{entry.suggestedName}</span>
              </div>
              <div className={styles.actions}>
                <button
                  type="button"
                  className={styles.createButton}
                  onClick={() => onCreate(entry)}
                >
                  Create
                </button>
                {onBrowse && (
                  <button
                    type="button"
                    className={styles.browseButton}
                    onClick={() => onBrowse(entry)}
                    aria-label={`Browse ${display.label} core boards`}
                  >
                    Browse →
                  </button>
                )}
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
      </div>
    </section>
  );
}
