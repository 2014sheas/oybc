import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../firebase/useAuth';
import { useBoards, useCoreBoardSlots, usePendingRecurringBoards, useRecurringBoardSpawn } from '../hooks';
import { isBoardExpired } from '../utils/boardDisplayUtils';
import { deleteBoard, deleteDraftWithCascade } from '../db/operations/boards';
import { RisoButton, RisoChip, RisoIcon } from '../components/riso';
import { CoreStrip } from '../components/boards/CoreStrip';
import { BoardCard } from '../components/boards/BoardCard';
import { RecurringWindowBanner } from '../components/boards/RecurringWindowBanner';
import { BoardStatus, type PendingRecurringBoard } from '@oybc/shared';
import styles from '../components/boards/Boards.module.css';

const FILTER_TABS = [
  { value: 'active', label: 'Active' },
  { value: 'completed', label: 'Completed' },
  { value: 'draft', label: 'Draft' },
  { value: 'all', label: 'All' },
] as const;

/**
 * BoardsPage (Riso) — billboard header + filter chips, the core-timeframe
 * strip, and a grid of board cards. Tapping a card opens the play view; the
 * core-strip cards open the per-timeframe window pager. Visual re-skin of the
 * existing logic (filtering, recurring-spawn, core slots).
 */
export function BoardsPage(): React.ReactElement {
  const { user } = useAuth();
  const navigate = useNavigate();
  const allBoards = useBoards(user?.id) ?? [];
  const coreBoardSlots = useCoreBoardSlots(user?.id);
  // Phase 6.1: detect new recurring windows that need a board created.
  const pendingRecurring = usePendingRecurringBoards(user?.id);
  // Phase 6.2: fire template spawns on Boards-tab mount (idempotent).
  useRecurringBoardSpawn(user?.id);
  const [activeFilter, setActiveFilter] = useState<string>('active');

  /** Delete a board from the boards list. Draft boards route through
   *  `deleteDraftWithCascade` so their placement rows are hard-deleted and
   *  tombstoned (a plain soft-delete would orphan the BoardTask rows and
   *  never queue them for sync); active/completed boards use `deleteBoard`,
   *  which intentionally leaves placements in place. The live query
   *  (`useBoards`) re-runs immediately since Dexie marks the row deleted, so
   *  the card disappears without a manual reload. */
  const handleDeleteBoard = async (id: string): Promise<void> => {
    const board = allBoards.find((b) => b.id === id);
    if (board?.status === BoardStatus.DRAFT) {
      await deleteDraftWithCascade(id);
    } else {
      await deleteBoard(id);
    }
  };

  /** Navigate to the wizard prefilled for the given pending window.
   *  No board is written here — lazy/observed only, per the recurring-boards
   *  invariant. The wizard creates the board when the user taps Save. */
  function handleRecurringSetUp(p: PendingRecurringBoard): void {
    navigate(`/create?recurringTimeframe=${p.timeframe}&windowDate=${p.startDate.slice(0, 10)}`);
  }

  const filteredBoards = allBoards.filter((b) => {
    if (activeFilter === 'all') return true;
    if (b.status !== activeFilter) return false;
    // The Active tab hides expired-but-still-ACTIVE boards (still visible under All).
    if (activeFilter === 'active' && isBoardExpired(b)) return false;
    return true;
  });

  return (
    <div>
      <div className={styles.head}>
        <div>
          <div className={styles.kicker}>Your boards</div>
          <h1 className={styles.title}>All boards</h1>
        </div>
        {allBoards.length > 0 && (
          <div className={styles.filters}>
            {FILTER_TABS.map((tab) => (
              <RisoChip
                key={tab.value}
                on={activeFilter === tab.value}
                onClick={() => setActiveFilter(tab.value)}
              >
                {tab.label}
              </RisoChip>
            ))}
          </div>
        )}
      </div>

      <CoreStrip
        slots={coreBoardSlots}
        onSelect={(slot) => {
          // A DRAFT core board for this window resumes the wizard (never
          // opens as the pager). No board → the pager handles the empty state.
          if (slot.currentBoard?.status === BoardStatus.DRAFT) {
            navigate(`/create?resumeDraft=${slot.currentBoard.id}`);
          } else {
            navigate(`/boards/core/${slot.timeframe}/${slot.windowStart.slice(0, 10)}`);
          }
        }}
      />

      <RecurringWindowBanner
        pending={pendingRecurring}
        onSetUp={handleRecurringSetUp}
      />

      {filteredBoards.length === 0 ? (
        <div className={styles.empty}>
          <h3 className={styles.emptyTitle}>
            {allBoards.length === 0 ? 'Nothing here yet.' : `No ${activeFilter} boards.`}
          </h3>
          <p className={styles.emptyText}>
            {allBoards.length === 0
              ? 'Start one — pick a timeframe, drop in your tasks, and print the board.'
              : 'Switch filters, or start a new board.'}
          </p>
          <RisoButton
            kind="primary"
            icon={<RisoIcon name="plus" size={16} />}
            onClick={() => navigate('/create')}
          >
            New board
          </RisoButton>
        </div>
      ) : (
        <div className={styles.grid}>
          {filteredBoards.map((board) => (
            <BoardCard
                key={board.id}
                board={board}
                onOpen={(id) => {
                  // Drafts never open as a playable board — tap routes to
                  // the wizard resume flow (cross-tab via ?resumeDraft).
                  if (board.status === BoardStatus.DRAFT) {
                    navigate(`/create?resumeDraft=${id}`);
                  } else {
                    navigate(`/boards/${id}`);
                  }
                }}
                onDelete={handleDeleteBoard}
              />
          ))}
        </div>
      )}
    </div>
  );
}
