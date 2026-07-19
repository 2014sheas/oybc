import { useNavigate } from 'react-router-dom';
import { AchievementTrigger, BoardStatus, Timeframe, computeStreak } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useBoards } from '../hooks/useBoards';
import { usePreferences } from '../hooks/usePreferences';
import { useBoardsPreviewCells } from '../hooks/useBoardsPreviewCells';
import { RisoButton, RisoCard, RisoIcon, RisoSectionLabel } from '../components/riso';
import { StreakPill } from '../components/home/StreakPill';
import { ResumePanel } from '../components/home/ResumePanel';
import { BoardRail } from '../components/home/BoardRail';
import homeStyles from '../components/home/Home.module.css';
import styles from './HomePage.module.css';

/** "Wednesday · June 25" — the greeting kicker date. */
function greetingDate(): string {
  return new Date().toLocaleDateString(undefined, {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  });
}

/**
 * Home / Resume — the signed-in landing.
 *
 * Greeting + daily-greenlog streak pill, a "Jump back in" resume panel for the
 * most-recently-active board, and a rail of the other active boards. All from
 * the boards' denormalized fields + the shared streaks engine. The board
 * posters are progress-accurate mini-grids; the real type-aware renderer
 * arrives in Phase 3 (see docs/RISO_WEB.md). No tutorial card — web has no
 * tutorial system (iOS-only).
 */
export function HomePage(): React.ReactElement {
  const navigate = useNavigate();
  const { user } = useAuth();
  const [prefs] = usePreferences();
  const boards = useBoards(user?.id);

  const activeBoards = boards
    .filter((b) => b.status === BoardStatus.ACTIVE)
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  const featured = activeBoards[0];
  const rail = activeBoards.slice(1, 5);
  // Perf follow-up (bugfix/board-preview-real-cells): ONE hoisted hook for
  // the rail's mini-grid data, not one per `BoardRail` card. `ResumePanel`'s
  // featured-board poster uses `RisoBoard` (Phase 3a renderer) directly, not
  // `BoardMiniGrid`, so it isn't part of this hoist.
  const railPreviewCellsByBoardId = useBoardsPreviewCells(rail, user?.id);

  const streak = computeStreak(
    Timeframe.DAILY,
    AchievementTrigger.GREENLOG,
    boards,
    prefs.weekStartDay,
    new Date()
  );

  const openBoard = (boardId: string): void => {
    navigate(`/boards/${boardId}`);
  };

  return (
    <div>
      <div className={styles.greet}>
        <div>
          <RisoSectionLabel variant="kicker">{greetingDate()}</RisoSectionLabel>
          <h1 className={styles.title}>Welcome back.</h1>
          <p className={styles.sub}>
            Pick up where you left off, or print something new. The press is warm.
          </p>
        </div>
        {streak > 0 && <StreakPill count={streak} />}
      </div>

      {featured ? (
        <>
          <div className={homeStyles.sectionHead}>
            <span className={homeStyles.secLabel}>Jump back in</span>
            <button type="button" className={homeStyles.sectionLink} onClick={() => navigate('/boards')}>
              All boards
              <RisoIcon name="chevron" size={13} />
            </button>
          </div>
          <ResumePanel board={featured} onOpen={openBoard} />

          {rail.length > 0 && (
            <>
              <div className={homeStyles.sectionHead}>
                <span className={homeStyles.secLabel}>Your other active boards</span>
                <button type="button" className={homeStyles.sectionLink} onClick={() => navigate('/boards')}>
                  View all
                  <RisoIcon name="chevron" size={13} />
                </button>
              </div>
              <BoardRail boards={rail} previewCellsByBoardId={railPreviewCellsByBoardId} onOpen={openBoard} />
            </>
          )}
        </>
      ) : (
        <>
          <div className={styles.sectionHead}>
            <h2 className={styles.sectionTitle}>Jump back in</h2>
          </div>
          <RisoCard padded className={styles.placeholder}>
            <p className={styles.placeholderText}>
              No active boards yet. Start one — pick a timeframe, drop in your tasks, and print the board.
            </p>
            <RisoButton
              kind="primary"
              icon={<RisoIcon name="plus" size={16} />}
              onClick={() => navigate('/create')}
            >
              New board
            </RisoButton>
          </RisoCard>
        </>
      )}
    </div>
  );
}
