import styles from './BoardsPage.module.css';

/**
 * BoardsPage — Shows the user's boards.
 *
 * Phase 1: Empty placeholder. Phase 2 will add the full board list
 * with filtering, progress indicators, and navigation to board play.
 */
export function BoardsPage(): React.ReactElement {
  return (
    <div className={styles.container}>
      <h1 className={styles.header}>Boards</h1>
      <div className={styles.emptyState}>
        <div className={styles.emptyIcon}>&#9776;</div>
        <p>
          No boards yet.<br />
          Head to the <strong>Create</strong> tab to build your first board!
        </p>
      </div>
    </div>
  );
}
