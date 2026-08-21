import styles from './CreateHubBoardCTA.module.css';

export type CreateHubBoardCTAVariant = 'primary' | 'secondary';

export interface CreateHubBoardCTAProps {
  /** Called when the user taps the card — parent is responsible for
   *  navigating to (or mounting) the wizard. */
  onClick: () => void;
  /** Phase 6.1d: when the parent renders `<CoreBoardsSection>` above
   *  this CTA, it passes `secondary` so this becomes a smaller
   *  affordance below the prominent core boards. Default `primary`
   *  keeps the original headline-card visual. */
  variant?: CreateHubBoardCTAVariant;
}

const ICON = '✨';
const ICON_SECONDARY = '+';
const TITLE = 'Start a new board';
const SUBTITLE = 'One-off or repeating — decide in setup.';

/**
 * CreateHubBoardCTA — Card that invites the user to start a new board.
 * Renders an action on the Create Hub; tapping it launches the 3-step
 * board-creation wizard. iOS twin: `CreateHubBoardCTAView`.
 *
 * P4 (Task Pools + Recurring Boards Rework) collapsed the former
 * `oneOff`/`recurring` `kind` axis into this single CTA — recurrence is
 * now chosen from the wizard's own Step 1 "Repeats" segmented, not a
 * separate entry point (the `?newRecurring=1` deep link retired
 * alongside it). Only `variant` remains: `primary` (large gradient
 * headline card) vs `secondary` (smaller flat card) — same destination,
 * different visual weight.
 */
export function CreateHubBoardCTA({
  onClick,
  variant = 'primary',
}: CreateHubBoardCTAProps): React.ReactElement {
  if (variant === 'secondary') {
    return (
      <button type="button" className={styles.cardSecondary} onClick={onClick}>
        <div className={styles.iconSecondary} aria-hidden="true">
          {ICON_SECONDARY}
        </div>
        <div className={styles.text}>
          <span className={styles.titleSecondary}>{TITLE}</span>
          <span className={styles.subtitleSecondary}>{SUBTITLE}</span>
        </div>
        <div className={styles.chevronSecondary} aria-hidden="true">
          ›
        </div>
      </button>
    );
  }
  return (
    <button type="button" className={styles.card} onClick={onClick}>
      <div className={styles.icon} aria-hidden="true">
        {ICON}
      </div>
      <div className={styles.text}>
        <span className={styles.title}>{TITLE}</span>
        <span className={styles.subtitle}>{SUBTITLE}</span>
      </div>
      <div className={styles.chevron} aria-hidden="true">
        ›
      </div>
    </button>
  );
}
