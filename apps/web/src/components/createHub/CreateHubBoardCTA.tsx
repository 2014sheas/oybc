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
 * Two visual variants — same destination, different visual weight:
 *   - `primary` (default): large gradient card with sparkle icon. Used
 *     when the parent has no pending core boards to surface above.
 *   - `secondary`: smaller flat card with muted styling. Same copy as
 *     primary; used when `PendingCoreBoardsSection` is the headline
 *     action above this CTA.
 *
 * The "Custom timeframe board" naming used pre-Phase-6.2-rework was
 * accurate when recurring lived in a separate form; post-rework the
 * wizard's Setup-step toggle handles both one-off and recurring, so
 * "custom" mislabels what tapping this actually does. Both variants
 * now share the universal "Start a new board" copy.
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
          <span className={styles.titleSecondary}>Start a new board</span>
          <span className={styles.subtitleSecondary}>
            Pick a timeframe, size, and tasks — optionally recurring.
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
