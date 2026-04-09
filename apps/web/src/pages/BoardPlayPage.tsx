import { useParams, Link } from 'react-router-dom';
import styles from './BoardPlayPage.module.css';

/**
 * BoardPlayPage — Full-screen bingo grid for a selected board.
 *
 * Phase 2: Placeholder. Phase 3 will add the full interactive grid
 * with task completion, bingo detection, and flash messages.
 */
export function BoardPlayPage(): React.ReactElement {
  const { id } = useParams<{ id: string }>();

  return (
    <div className={styles.container}>
      <Link to="/boards" className={styles.backLink}>&larr; Back to boards</Link>
      <div className={styles.placeholder}>
        <p>Board play view coming in Phase 3</p>
        <p className={styles.boardId}>Board: {id}</p>
      </div>
    </div>
  );
}
