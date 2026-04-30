import styles from './CreateHubBoardCTA.module.css';

export interface CreateHubBoardCTAProps {
  /** Called when the user taps the card — parent is responsible for
   *  navigating to (or mounting) the wizard. */
  onClick: () => void;
}

/**
 * CreateHubBoardCTA — Large landing-page card that invites the user
 * to start a new board. Renders the primary action on the Create
 * Hub; tapping it launches the 3-step board-creation wizard. iOS
 * twin: `CreateHubBoardCTAView`.
 */
export function CreateHubBoardCTA({ onClick }: CreateHubBoardCTAProps): React.ReactElement {
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
