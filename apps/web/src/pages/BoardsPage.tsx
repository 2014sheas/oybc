import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../firebase/useAuth';
import { useBoards, usePendingRecurringBoards } from '../hooks';
import { FilterTabs } from '../components/FilterTabs';
import { BoardListItem } from '../components/BoardListItem';
import { RecurringBoardsBanner } from '../components/RecurringBoardsBanner';
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
  const pendingRecurring = usePendingRecurringBoards(user?.id);
  const [activeFilter, setActiveFilter] = useState('all');

  const filteredBoards = allBoards.filter((b) => {
    if (activeFilter === 'all') return true;
    return b.status === activeFilter;
  });

  return (
    <div className={styles.container}>
      <h1 className={styles.header}>Boards</h1>

      <RecurringBoardsBanner pending={pendingRecurring} />

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
            />
          ))}
        </div>
      )}
    </div>
  );
}
