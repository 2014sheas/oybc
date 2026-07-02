import { useParams, Link } from 'react-router-dom';
import { BoardStatus } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useBoard } from '../hooks';
import { BoardPlaySurface } from '../components/BoardPlaySurface';
import { DraftResumePrompt } from '../components/boards/DraftResumePrompt';
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

  if (board.status === BoardStatus.DRAFT) {
    // Catch-all draft guard: a DRAFT board is never rendered as a playable
    // grid. Shows a "Resume draft" prompt instead (mirrors iOS
    // BoardPlayView.draftResumeSection). Primary surfaces (BoardsPage card
    // taps, CoreStrip taps, CoreBoardBrowser row taps) route to
    // /create?resumeDraft before reaching here — this is the safety net for
    // direct-URL hits, task-detail Usage jumps, and any other secondary path.
    return (
      <div className={styles.container}>
        <Link to="/boards" className={styles.backLink}>&larr; Back to boards</Link>
        <DraftResumePrompt boardId={board.id} boardName={board.name} />
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
