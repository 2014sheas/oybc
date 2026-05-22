import { useParams, Link } from 'react-router-dom';
import { useAuth } from '../firebase/useAuth';
import { useBoard } from '../hooks';
import { BoardPlaySurface } from '../components/BoardPlaySurface';
import styles from './BoardPlayPage.module.css';

/**
 * BoardPlayPage — `/boards/:id`. Resolves the id to a board, handles
 * loading / not-found, and renders `BoardPlaySurface` with a back link.
 */
export function BoardPlayPage(): React.ReactElement {
  const { id } = useParams<{ id: string }>();
  const { user } = useAuth();
  const boardQuery = useBoard(id);
  const board = boardQuery === undefined ? undefined : (boardQuery ?? null);

  if (board === undefined) {
    return (
      <div className={styles.container}>
        <p className={styles.emptyState}>Loading…</p>
      </div>
    );
  }
  if (board === null) {
    return (
      <div className={styles.container}>
        <Link to="/boards" className={styles.backLink}>&larr; Back to boards</Link>
        <div className={styles.notFound}><p>Board not found</p></div>
      </div>
    );
  }

  return (
    <BoardPlaySurface
      board={board}
      userId={user?.id}
      header={<Link to="/boards" className={styles.backLink}>&larr; Back to boards</Link>}
    />
  );
}
