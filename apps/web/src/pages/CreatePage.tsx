import styles from './CreatePage.module.css';

/**
 * CreatePage — Task pool builder + board creation.
 *
 * Phase 1: Placeholder. Phase 4 will add the full creation flow
 * with task selection, inline task creator, and BoardCreatorPanel.
 */
export function CreatePage(): React.ReactElement {
  return (
    <div className={styles.container}>
      <h1 className={styles.header}>Create</h1>
      <div className={styles.placeholder}>
        <div className={styles.placeholderIcon}>&#43;</div>
        <p>
          Build tasks, assemble your pool,<br />
          and create a new bingo board.
        </p>
      </div>
    </div>
  );
}
