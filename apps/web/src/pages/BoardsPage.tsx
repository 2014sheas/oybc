import { useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  TaskType,
  Timeframe,
  CenterSquareType,
  fisherYatesShuffle,
} from '@oybc/shared';
import { useAuth } from '../firebase/AuthContext';
import { useBoards } from '../hooks';
import { createTask } from '../db/operations/tasks';
import { createBoard } from '../db/operations/boards';
import { createBoardTask } from '../db/operations/boardTasks';
import { FilterTabs } from '../components/FilterTabs';
import { BoardListItem } from '../components/BoardListItem';
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
  const [activeFilter, setActiveFilter] = useState('all');
  const [isCreatingDemo, setIsCreatingDemo] = useState(false);

  // Temporary demo board creator — will be removed when Create tab is built (Phase 4)
  const handleCreateDemo = useCallback(async () => {
    if (!user || isCreatingDemo) return;
    setIsCreatingDemo(true);
    try {
      // 8 tasks for a 3x3 board with FREE center — mix of all types for testing
      const taskDefs = [
        { type: TaskType.NORMAL, title: 'Meditate' },
        { type: TaskType.NORMAL, title: 'Call a friend' },
        { type: TaskType.NORMAL, title: 'Cook dinner' },
        { type: TaskType.NORMAL, title: 'Write in journal' },
        { type: TaskType.COUNTING, title: 'Read 10 pages', action: 'Read', unit: 'pages', maxCount: 10 },
        { type: TaskType.COUNTING, title: 'Walk 3 km', action: 'Walk', unit: 'km', maxCount: 3 },
        {
          type: TaskType.PROGRESS, title: 'Morning Routine',
          steps: [
            { title: 'Brush teeth', type: TaskType.NORMAL },
            { title: 'Stretch', type: TaskType.NORMAL },
            { title: 'Breakfast', type: TaskType.NORMAL },
          ],
        },
        {
          type: TaskType.PROGRESS, title: 'Clean House',
          steps: [
            { title: 'Vacuum', type: TaskType.NORMAL },
            { title: 'Dishes', type: TaskType.NORMAL },
          ],
        },
      ];
      const tasks = [];
      for (const def of taskDefs) {
        tasks.push(await createTask(user.id, def));
      }
      const shuffled = fisherYatesShuffle([...tasks]);
      const board = await createBoard(user.id, {
        name: `Demo Board ${allBoards.length + 1}`,
        boardSize: 3,
        timeframe: Timeframe.CUSTOM,
        startDate: new Date().toISOString(),
        endDate: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
        centerSquareType: CenterSquareType.FREE,
        isRandomized: true,
      });
      let idx = 0;
      for (let row = 0; row < 3; row++) {
        for (let col = 0; col < 3; col++) {
          if (row === 1 && col === 1) continue;
          if (idx >= shuffled.length) break;
          await createBoardTask({ boardId: board.id, taskId: shuffled[idx].id, row, col, isCenter: false });
          idx++;
        }
      }
      navigate(`/boards/${board.id}`);
    } catch (err) {
      console.error('Demo board creation failed:', err);
    } finally {
      setIsCreatingDemo(false);
    }
  }, [user, isCreatingDemo, allBoards.length, navigate]);

  const filteredBoards = allBoards.filter((b) => {
    if (activeFilter === 'all') return true;
    return b.status === activeFilter;
  });

  return (
    <div className={styles.container}>
      <div className={styles.headerRow}>
        <h1 className={styles.header}>Boards</h1>
        <button
          type="button"
          className={styles.demoButton}
          onClick={() => void handleCreateDemo()}
          disabled={isCreatingDemo}
        >
          {isCreatingDemo ? 'Creating...' : '+ Demo Board'}
        </button>
      </div>

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
          <div className={styles.emptyIcon}>&#9776;</div>
          <p>
            {allBoards.length === 0 ? (
              <>
                No boards yet.<br />
                Head to the <strong>Create</strong> tab to build your first board!
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
