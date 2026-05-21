import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../firebase/useAuth';
import {
  useBoards,
  useCoreBoardSlots,
  useRecurringBoardSpawn,
} from '../hooks';
import { FilterTabs } from '../components/FilterTabs';
import { BoardListItem } from '../components/BoardListItem';
import { CoreBoardsSection } from '../components/CoreBoardsSection';
import { deleteBoard } from '../db/operations/boards';
import { isBoardExpired } from '../utils/boardDisplayUtils';
import styles from './BoardsPage.module.css';

const FILTER_TABS = [
  { value: 'all', label: 'All' },
  { value: 'active', label: 'Active' },
  { value: 'completed', label: 'Completed' },
  { value: 'draft', label: 'Draft' },
];

/**
 * BoardsPage — Shows the user's boards with status filtering.
 *
 * Each board row shows name, progress, bingo count, timeframe, expiry, and status.
 * Tapping a board navigates to the board play view.
 */
export function BoardsPage(): React.ReactElement {
  const { user } = useAuth();
  const navigate = useNavigate();
  const allBoards = useBoards(user?.id) ?? [];
  const coreBoardSlots = useCoreBoardSlots(user?.id);
  // Phase 6.2: fire template spawns on Boards-tab mount. The hook is
  // structurally idempotent — repeated mounts are no-ops once
  // `lastSpawnedWindowKey` is written. We don't currently consume the
  // returned digest here; the Profile recurring-templates page does its
  // own synchronous validation against the library to surface "needs
  // attention" badges (see `RecurringTemplatesPage` + the
  // `templateAttention` memo it derives).
  useRecurringBoardSpawn(user?.id);
  // Default to 'active' so the boards a user is currently playing are
  // front-and-center. They can switch to 'all' for drafts / completed /
  // expired boards. Session-local — no UserPreferences persistence.
  const [activeFilter, setActiveFilter] = useState('active');

  const filteredBoards = allBoards.filter((b) => {
    if (activeFilter === 'all') return true;
    if (b.status !== activeFilter) return false;
    // Expiry-aware: a board whose status is ACTIVE but whose endDate
    // has passed is no longer "active" for the user's purposes.
    // Excluded from the Active tab (still visible under All). Other
    // filters (Completed, Draft) don't apply the expiry check.
    if (activeFilter === 'active' && isBoardExpired(b)) return false;
    return true;
  });

  return (
    <div className={styles.container}>
      <h1 className={styles.header}>Boards</h1>

      <CoreBoardsSection
        slots={coreBoardSlots}
        // Whole-row tap → per-timeframe Core Board Browser. The
        // browser handles state-specific actions in cell form
        // (Create today's cell when slot is empty, board cell when
        // it's already created, plus past/future windows).
        onSelect={(slot) => navigate(`/boards/core/${slot.timeframe}`)}
      />

      {allBoards.length > 0 && (
        <div className={styles.filterRow}>
          <FilterTabs
            tabs={FILTER_TABS}
            activeTab={activeFilter}
            onTabChange={setActiveFilter}
          />
        </div>
      )}

      {filteredBoards.length === 0 ? (
        <div className={styles.emptyState}>
          <div className={styles.emptyIcon} aria-hidden="true">
            &#9638;
          </div>
          <p>
            {allBoards.length === 0 ? (
              <>
                No boards yet.<br />
                Head to the <strong>Create</strong> tab to build your first board.
              </>
            ) : (
              <>No {activeFilter} boards found.</>
            )}
          </p>
        </div>
      ) : (
        <div className={styles.boardList}>
          {filteredBoards.map((board) => (
            <BoardListItem
              key={board.id}
              board={board}
              onClick={() => navigate(`/boards/${board.id}`)}
              onDelete={(id) => deleteBoard(id)}
            />
          ))}
        </div>
      )}
    </div>
  );
}
