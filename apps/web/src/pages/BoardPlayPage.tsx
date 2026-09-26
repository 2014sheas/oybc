import { useParams, Link, Navigate } from 'react-router-dom';
import { BoardStatus, coreWindowRouteForBoard } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useBoard, usePreferences } from '../hooks';
import { BoardPlaySurface } from '../components/BoardPlaySurface';
import { DraftResumePrompt } from '../components/boards/DraftResumePrompt';
import styles from './BoardPlayPage.module.css';

/**
 * BoardPlayPage — `/boards/:id`. Resolves the id to a board, handles
 * loading / not-found, and renders `BoardPlaySurface` with a back link.
 *
 * A **core** board never renders here: it redirects (replace) into the
 * per-window pager (`/boards/core/:timeframe/:date`), so every entry
 * point that only knows a board id — board cards, the closing-out
 * banner, task-detail Usage jumps, counter member cards, the
 * post-create landing — gets the same swipe-to-browse chrome the Core
 * Boards strip opens. iOS twin: `MainTabView.pushBoard(_:)`.
 */
export function BoardPlayPage(): React.ReactElement {
  const { id } = useParams<{ id: string }>();
  const { user } = useAuth();
  // The pager keys weekly windows by the week-start preference, so wait
  // for the live value: redirecting on the default would send a Sunday-
  // start weekly board to an empty Monday-start window.
  const [preferences, , preferencesReady] = usePreferences();
  const boardQuery = useBoard(id);
  const board = boardQuery === undefined ? undefined : (boardQuery ?? null);

  if (board === undefined || !preferencesReady) {
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

  const coreRoute = coreWindowRouteForBoard(board, preferences.weekStartDay);
  if (coreRoute) {
    return (
      <Navigate
        to={`/boards/core/${coreRoute.timeframe}/${coreRoute.windowStart.slice(0, 10)}`}
        replace
      />
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
      // Board-integrity PR-5 (Item 6): key by board.id so React remounts
      // BoardPlaySurface (and its useBoardPlay/useBoardPlayData hook state —
      // edit-mode drafts, staged rearranges, etc.) whenever the route's :id
      // param changes to a DIFFERENT board, instead of reusing the same
      // component instance across boards. Currently unreachable in practice
      // (no in-page nav swaps :id under this route without a full page
      // load), but structurally undefended without it — a stale edit-draft
      // diffed against a NEW board's live placements could hard-delete real
      // placements it never staged.
      key={board.id}
      board={board}
      userId={user?.id}
      header={<Link to="/boards" className={styles.backLink}>&larr; Back to boards</Link>}
    />
  );
}
