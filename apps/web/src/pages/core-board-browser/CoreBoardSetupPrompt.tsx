import { Timeframe, formatTimeframeLabel } from '@oybc/shared';
import styles from './CoreBoardBrowserPage.module.css';

export interface CoreBoardSetupPromptProps {
  timeframe: Timeframe;
  /** Local ISO window start. Used for the label + the create deep-link date. */
  windowStart: string;
  /** Window end already passed — render "Backfill" affordance instead of "Set up". */
  isPast: boolean;
  /** Launch the wizard prefilled for this window. */
  onSetUp: () => void;
}

/**
 * CoreBoardSetupPrompt — shown by the pager when no core board exists for
 * the current window. No DB row is written until the user acts (lazy, per
 * the no-auto-spawn rule). Tapping the button launches the wizard prefilled
 * for this window via the same deep-link the browser's empty cell uses.
 */
export function CoreBoardSetupPrompt({
  timeframe,
  windowStart,
  isPast,
  onSetUp,
}: CoreBoardSetupPromptProps): React.ReactElement {
  const label = formatTimeframeLabel(timeframe, windowStart);
  return (
    <div className={styles.setupPrompt}>
      <div className={styles.setupIcon} aria-hidden="true">
        📅
      </div>
      <p className={styles.setupText}>No board for {label} yet.</p>
      <button type="button" className={styles.setupButton} onClick={onSetUp}>
        {isPast ? 'Backfill' : 'Set up'} {label}
      </button>
    </div>
  );
}
