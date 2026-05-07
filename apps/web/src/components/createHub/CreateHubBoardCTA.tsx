import styles from './CreateHubBoardCTA.module.css';

export type CreateHubBoardCTAVariant = 'primary' | 'secondary';

export interface CreateHubBoardCTAProps {
  /** Called when the user taps the card — parent is responsible for
   *  navigating to (or mounting) the wizard. */
  onClick: () => void;
  /** Phase 6.1d: when the parent renders `<PendingCoreBoardsSection>`
   *  above this CTA, it passes `secondary` so this becomes a smaller
   *  custom-board affordance below the prominent core boards. Default
   *  `primary` keeps the original headline-card visual for users with no
   *  pending core boards. */
  variant?: CreateHubBoardCTAVariant;
}

/**
 * CreateHubBoardCTA — Card that invites the user to start a new board.
 * Renders the primary action on the Create Hub; tapping it launches the
 * 3-step board-creation wizard. iOS twin: `CreateHubBoardCTAView`.
 *
 * Two visual variants:
 *   - `primary` (default): large gradient card with sparkle icon. Used
 *     when the parent has no pending core boards to surface above.
 *   - `secondary`: smaller flat card with muted styling + reframed copy
 *     ("Custom timeframe board"). Used when `PendingCoreBoardsSection`
 *     is the headline action above this CTA.
 */
export function CreateHubBoardCTA({
  onClick,
  variant = 'primary',
}: CreateHubBoardCTAProps): React.ReactElement {
  if (variant === 'secondary') {
    return (
      <button type="button" className={styles.cardSecondary} onClick={onClick}>
        <div className={styles.iconSecondary} aria-hidden="true">
          +
        </div>
        <div className={styles.text}>
          <span className={styles.titleSecondary}>Custom timeframe board</span>
          <span className={styles.subtitleSecondary}>
            For one-off goals that don't fit a recurring window.
          </span>
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
        ✨
      </div>
      <div className={styles.text}>
        <span className={styles.title}>Start a new board</span>
        <span className={styles.subtitle}>Set it up, pick your tasks, and activate.</span>
      </div>
      <div className={styles.chevron} aria-hidden="true">
        ›
      </div>
    </button>
  );
}
