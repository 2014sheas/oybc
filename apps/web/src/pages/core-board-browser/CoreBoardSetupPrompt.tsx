import { Timeframe, formatTimeframeLabel } from '@oybc/shared';
import { RisoButton, RisoIcon } from '../../components/riso';
import styles from './CoreWindow.module.css';

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
 * for this window. Rendered inside the pager's dashed empty-window frame.
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
      <p className={styles.setupText}>No board for {label} yet.</p>
      <p className={styles.setupSub}>
        {isPast
          ? 'Add a past board to fill in this window.'
          : 'Set up a board for this window to start tracking your goals.'}
      </p>
      <RisoButton
        kind="primary"
        icon={<RisoIcon name="plus" size={15} />}
        onClick={onSetUp}
      >
        {isPast ? 'Backfill' : 'Set up'} {label}
      </RisoButton>
    </div>
  );
}
