import { useState, useCallback } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType,
  Timeframe,
  CenterSquareType,
  BoardStatus,
  fisherYatesShuffle,
  isTimeframeExpired,
  formatTimeframeLabel,
  type Task,
  type TaskStep,
  type BoardTask,
} from '@oybc/shared';
import { db } from '../../db/database';
import { createTask } from '../../db/operations/tasks';
import { createBoard, activateBoard } from '../../db/operations/boards';
import { createBoardTask } from '../../db/operations/boardTasks';
import { handleTaskCompletion } from '../../db/operations/orchestration';
import { useBoards, useBoard, useBoardTasks, useTasks } from '../../hooks';
import { taskToSquareData, boardTaskToSquareState } from '../../db/adapters';
import {
  InteractiveTaskSquare,
  DetailModal,
  FloatingContextMenu,
  type ContextMenuState,
} from '../InteractiveTaskSquare';
import { PLAYGROUND_USER_ID, SUCCESS_DISMISS_MS } from './playgroundUtils';
import styles from './BoardLifecyclePlayground.module.css';

// ─── Constants ────────────────────────────────────────────────────────────────

/** How long the bingo flash message is shown before auto-dismissing (ms) */
const BINGO_FLASH_MS = SUCCESS_DISMISS_MS;

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * A flash message shown after a bingo or greenlog event.
 */
interface FlashMessage {
  text: string;
  variant: 'bingo' | 'greenlog';
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * BoardLifecyclePlayground demonstrates the full board lifecycle:
 * - Board list with status badges and progress indicators
 * - Board selection for interactive play
 * - Automatic bingo detection with flash messages on every task interaction
 * - Automatic DRAFT → ACTIVE transition when a board is first played
 * - Automatic board completion (GREENLOG) when all squares are filled
 *
 * All DB writes go through `handleTaskCompletion()` in orchestration.ts so
 * bingo detection and board stats remain consistent with the production path.
 */
export function BoardLifecyclePlayground(): React.ReactElement {
  // ── Local state ──────────────────────────────────────────────────────────

  /** ID of the board currently selected for play */
  const [selectedBoardId, setSelectedBoardId] = useState<string | null>(null);

  /** Flash message shown briefly after a bingo or greenlog */
  const [flashMessage, setFlashMessage] = useState<FlashMessage | null>(null);

  /** Board task ID open in the DetailModal (progress tasks) */
  const [selectedSquareId, setSelectedSquareId] = useState<string | null>(null);

  /** State for the FloatingContextMenu */
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);

  /** True while the demo board creation async flow is running */
  const [isSettingUp, setIsSettingUp] = useState(false);

  // ── Reactive data ────────────────────────────────────────────────────────

  const allBoards = useBoards(PLAYGROUND_USER_ID) ?? [];
  const selectedBoard = useBoard(selectedBoardId ?? undefined) ?? null;
  const boardTasks = useBoardTasks(selectedBoardId ?? undefined) ?? [];
  const allTasks = useTasks(PLAYGROUND_USER_ID) ?? [];

  const allTaskSteps: TaskStep[] =
    useLiveQuery(
      () => db.taskSteps.filter((s: TaskStep) => !s.isDeleted).toArray(),
      []
    ) ?? [];

  // Build a task lookup map for fast access by ID
  const taskMap: Record<string, Task> = {};
  for (const t of allTasks) taskMap[t.id] = t;

  // ── Flash message helper ─────────────────────────────────────────────────

  /**
   * Shows a bingo or greenlog flash message that auto-dismisses.
   *
   * @param text - The message text
   * @param variant - 'bingo' or 'greenlog' (controls styling)
   */
  function showFlash(text: string, variant: FlashMessage['variant']): void {
    setFlashMessage({ text, variant });
    setTimeout(() => setFlashMessage(null), BINGO_FLASH_MS);
  }

  // ── Demo board creation ──────────────────────────────────────────────────

  /**
   * Creates a demo 3×3 board with a FREE center square. Defines 9 tasks
   * (2 counting, 2 progress, 5 normal), shuffles them, and places 8 on the grid.
   * Reuses the same task definitions as BoardTaskSelectionPlayground's demo
   * board so there is a consistent reference point across playground sections.
   */
  const handleCreateDemoBoard = useCallback(async (): Promise<void> => {
    setIsSettingUp(true);
    try {
      const demoStart = new Date().toISOString();
      const demoEnd = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

      const taskDefs = [
        { type: TaskType.COUNTING, title: 'Read 50 pages', action: 'Read', unit: 'pages', maxCount: 50 },
        { type: TaskType.COUNTING, title: 'Walk 10 km', action: 'Walk', unit: 'km', maxCount: 10 },
        {
          type: TaskType.PROGRESS,
          title: 'Weekly Workout',
          steps: [
            { title: 'Monday run', type: TaskType.NORMAL },
            { title: 'Wednesday weights', type: TaskType.NORMAL },
            { title: 'Friday yoga', type: TaskType.NORMAL },
          ],
        },
        {
          type: TaskType.PROGRESS,
          title: 'Clean House',
          steps: [
            { title: 'Vacuum', type: TaskType.NORMAL },
            { title: 'Dust', type: TaskType.NORMAL },
            { title: 'Mop', type: TaskType.NORMAL },
          ],
        },
        { type: TaskType.NORMAL, title: 'Meditate' },
        { type: TaskType.NORMAL, title: 'Call a friend' },
        { type: TaskType.NORMAL, title: 'Cook dinner' },
        { type: TaskType.NORMAL, title: 'Write in journal' },
        { type: TaskType.NORMAL, title: 'Read a chapter' },
      ];

      const createdTasks: Task[] = [];
      for (const def of taskDefs) {
        const task = await createTask(PLAYGROUND_USER_ID, def);
        createdTasks.push(task);
      }

      const shuffled = fisherYatesShuffle([...createdTasks]);
      const boardSize = 3;

      const board = await createBoard(PLAYGROUND_USER_ID, {
        name: `Demo Board ${allBoards.length + 1}`,
        boardSize,
        timeframe: Timeframe.CUSTOM,
        startDate: demoStart,
        endDate: demoEnd,
        centerSquareType: CenterSquareType.FREE,
        isRandomized: true,
      });

      let taskIndex = 0;
      for (let row = 0; row < boardSize; row++) {
        for (let col = 0; col < boardSize; col++) {
          const isCenter = row === 1 && col === 1;
          if (isCenter) continue;
          if (taskIndex >= shuffled.length) break;
          await createBoardTask({
            boardId: board.id,
            taskId: shuffled[taskIndex].id,
            row,
            col,
            isCenter: false,
          });
          taskIndex++;
        }
      }

      // Auto-select and activate the newly created board
      void handleSelectBoard(board.id);
    } catch (err) {
      console.error('BoardLifecyclePlayground: demo board creation failed', err);
    } finally {
      setIsSettingUp(false);
    }
  }, [allBoards.length]);

  // ── Board play interactions ──────────────────────────────────────────────

  /**
   * Selects a board for play. If the board is in DRAFT status it is
   * automatically transitioned to ACTIVE.
   *
   * @param boardId - The board to select
   */
  const handleSelectBoard = useCallback(async (boardId: string): Promise<void> => {
    setSelectedBoardId(boardId);
    setSelectedSquareId(null);
    setContextMenu(null);
    // Auto-activate DRAFT boards the moment the player selects them
    await activateBoard(boardId);
  }, []);

  /**
   * Fires a task completion through the orchestration layer, then inspects
   * the result to trigger bingo/greenlog flash messages.
   *
   * @param boardId - The board containing the task
   * @param boardTaskId - The specific BoardTask to update
   * @param updates - Partial update to apply
   */
  const handleComplete = useCallback(
    async (
      boardId: string,
      boardTaskId: string,
      updates: {
        isCompleted?: boolean;
        currentCount?: number;
        completedStepIds?: string[];
      }
    ): Promise<void> => {
      const result = await handleTaskCompletion(boardId, boardTaskId, updates);
      if (result.isGreenlog) {
        showFlash('GREENLOG! Board complete!', 'greenlog');
      } else if (result.newBingos.length > 0) {
        showFlash(`Bingo! ${result.newBingos.join(', ')}`, 'bingo');
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    []
  );

  // ── Derived data for board play grid ────────────────────────────────────

  // Sort board tasks row-major for consistent rendering
  const sortedBoardTasks = [...boardTasks].sort((a, b) =>
    a.row !== b.row ? a.row - b.row : a.col - b.col
  );

  const gridSize = selectedBoard?.boardSize ?? 3;

  // Build a position lookup for the grid renderer
  const btByPosition: Record<string, BoardTask> = {};
  for (const bt of sortedBoardTasks) {
    btByPosition[`${bt.row}-${bt.col}`] = bt;
  }

  // ── Expiry helpers ───────────────────────────────────────────────────────

  /**
   * Returns whether a board is expired (past its end date and not Custom timeframe).
   */
  function isBoardExpired(board: { timeframe: string; endDate?: string }): boolean {
    if (board.timeframe === Timeframe.CUSTOM) return false;
    if (!board.endDate) return false;
    return isTimeframeExpired(board.endDate);
  }

  /**
   * Returns a human-readable expiry indicator for the board list.
   * - "No deadline" for Custom
   * - "Expired" for past-due
   * - "N days left" for active timeframes
   */
  function getExpiryLabel(board: { timeframe: string; endDate?: string }): string {
    if (board.timeframe === Timeframe.CUSTOM) return 'No deadline';
    if (!board.endDate) return 'No deadline';
    if (isTimeframeExpired(board.endDate)) return 'Expired';
    const msLeft = new Date(board.endDate).getTime() - Date.now();
    const daysLeft = Math.ceil(msLeft / (1000 * 60 * 60 * 24));
    if (daysLeft <= 0) return 'Expires today';
    if (daysLeft === 1) return '1 day left';
    return `${daysLeft} days left`;
  }

  const isSelectedBoardExpired = selectedBoard ? isBoardExpired(selectedBoard) : false;

  // ── Status badge helper ──────────────────────────────────────────────────

  /**
   * Returns the CSS class for a status badge based on board status.
   *
   * @param status - The BoardStatus value
   */
  function statusBadgeClass(status: BoardStatus): string {
    if (status === BoardStatus.ACTIVE) return styles.badgeActive;
    if (status === BoardStatus.COMPLETED) return styles.badgeCompleted;
    return styles.badgeDraft;
  }

  /**
   * Returns the human-readable label for a board status.
   *
   * @param status - The BoardStatus value
   */
  function statusLabel(status: BoardStatus): string {
    if (status === BoardStatus.ACTIVE) return 'ACTIVE';
    if (status === BoardStatus.COMPLETED) return 'COMPLETED';
    return 'DRAFT';
  }

  // ── Render ───────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      {/* ── Bingo / Greenlog flash message ── */}
      {flashMessage && (
        <div
          className={`${styles.flashMessage} ${flashMessage.variant === 'greenlog' ? styles.flashGreenlog : styles.flashBingo}`}
          role="status"
          aria-live="polite"
        >
          {flashMessage.text}
        </div>
      )}

      {/* ── Board List section ── */}
      <section className={styles.section}>
        <div className={styles.sectionHeader}>
          <h3 className={styles.sectionTitle}>Boards</h3>
          <button
            type="button"
            className={styles.createButton}
            onClick={() => void handleCreateDemoBoard()}
            disabled={isSettingUp}
          >
            {isSettingUp ? 'Creating...' : '+ Create Demo Board'}
          </button>
        </div>

        {allBoards.length === 0 ? (
          <p className={styles.emptyState}>
            No boards yet. Click "Create Demo Board" to get started.
          </p>
        ) : (
          <div className={styles.boardList}>
            {allBoards.map((board) => {
              const isSelected = selectedBoardId === board.id;
              const hasBingos = (board.linesCompleted ?? 0) > 0;
              const progressPct =
                board.totalTasks > 0
                  ? Math.round((board.completedTasks / board.totalTasks) * 100)
                  : 0;
              return (
                <button
                  key={board.id}
                  type="button"
                  className={`${styles.boardRow} ${isSelected ? styles.boardRowSelected : ''}`}
                  onClick={() => void handleSelectBoard(board.id)}
                  aria-pressed={isSelected}
                >
                  <div className={styles.boardRowLeft}>
                    <span className={styles.boardRowName}>{board.name}</span>
                    {board.timeframe !== Timeframe.CUSTOM && board.startDate && (
                      <span className={styles.timeframeLabel}>
                        {formatTimeframeLabel(board.timeframe as Timeframe, board.startDate)}
                      </span>
                    )}
                    <div className={styles.boardRowMeta}>
                      <div
                        className={styles.progressBar}
                        role="progressbar"
                        aria-valuenow={progressPct}
                        aria-valuemin={0}
                        aria-valuemax={100}
                      >
                        <div
                          className={styles.progressFill}
                          style={{ width: `${progressPct}%` }}
                        />
                      </div>
                      <span className={styles.boardRowProgress}>
                        {board.completedTasks}/{board.totalTasks} tasks
                      </span>
                      {hasBingos && (
                        <span className={styles.bingoCount}>
                          {board.linesCompleted} bingo{board.linesCompleted !== 1 ? 's' : ''}
                        </span>
                      )}
                      <span className={`${styles.expiryLabel} ${isBoardExpired(board) ? styles.expiryExpired : ''}`}>
                        {getExpiryLabel(board)}
                      </span>
                    </div>
                  </div>
                  <span className={`${styles.statusBadge} ${statusBadgeClass(board.status as BoardStatus)}`}>
                    {statusLabel(board.status as BoardStatus)}
                  </span>
                </button>
              );
            })}
          </div>
        )}
      </section>

      {/* ── Board Play section (shown only when a board is selected) ── */}
      {selectedBoard && (
        <section className={styles.section}>
          {/* Play header */}
          <div className={styles.playHeader}>
            <div className={styles.playHeaderLeft}>
              <span className={styles.nowPlaying}>Now Playing</span>
              <h3 className={styles.playBoardName}>{selectedBoard.name}</h3>
            </div>
            <span className={`${styles.statusBadge} ${statusBadgeClass(selectedBoard.status as BoardStatus)}`}>
              {statusLabel(selectedBoard.status as BoardStatus)}
            </span>
          </div>

          {/* Interactive grid */}
          {sortedBoardTasks.length === 0 ? (
            <p className={styles.emptyState}>Loading board tasks…</p>
          ) : (
            <div
              className={styles.playGrid}
              style={{
                gridTemplateColumns: `repeat(${gridSize}, 90px)`,
              }}
            >
              {(() => {
                const cells: React.ReactElement[] = [];

                for (let row = 0; row < gridSize; row++) {
                  for (let col = 0; col < gridSize; col++) {
                    const bt = btByPosition[`${row}-${col}`];
                    const isCenter =
                      gridSize % 2 === 1 &&
                      row === Math.floor(gridSize / 2) &&
                      col === Math.floor(gridSize / 2);

                    if (!bt) {
                      if (isCenter && (selectedBoard.centerSquareType === CenterSquareType.FREE ||
                          selectedBoard.centerSquareType === CenterSquareType.CUSTOM_FREE)) {
                        // FREE center square — auto-completed, non-interactive
                        cells.push(
                          <div key={`center-${row}-${col}`} className={styles.freeSquare}>
                            FREE
                          </div>
                        );
                      } else {
                        // Empty placeholder to preserve CSS grid alignment
                        cells.push(
                          <div key={`empty-${row}-${col}`} className={styles.freeSquare} />
                        );
                      }
                      continue;
                    }

                    const task = taskMap[bt.taskId];
                    if (!task) continue;

                    const squareData = taskToSquareData(task, allTaskSteps);
                    const squareState = boardTaskToSquareState(bt);

                    cells.push(
                      <InteractiveTaskSquare
                        key={bt.id}
                        sq={squareData}
                        state={squareState}
                        onAct={() => {
                          if (isSelectedBoardExpired) return;
                          if (squareData.type === 'progress') {
                            setSelectedSquareId(bt.id);
                          } else if (squareData.type === 'counting') {
                            void handleComplete(selectedBoard.id, bt.id, {
                              currentCount: (bt.currentCount ?? 0) + 1,
                            });
                          } else {
                            void handleComplete(selectedBoard.id, bt.id, {
                              isCompleted: !bt.isCompleted,
                            });
                          }
                        }}
                        onContextMenu={(e) => {
                          setContextMenu({ squareId: bt.id, x: e.clientX, y: e.clientY });
                        }}
                      />
                    );
                  }
                }

                return cells;
              })()}
            </div>
          )}

          {/* Expired banner */}
          {isSelectedBoardExpired && (
            <div className={styles.expiredBanner}>
              Board expired on {selectedBoard.endDate?.split('T')[0] ?? 'unknown date'}
            </div>
          )}

          {/* Stats bar */}
          <div className={styles.statsBar}>
            <span className={styles.statItem}>
              <strong>Progress:</strong>{' '}
              {selectedBoard.completedTasks}/{selectedBoard.totalTasks}
              {selectedBoard.totalTasks > 0 && (
                <> ({Math.round((selectedBoard.completedTasks / selectedBoard.totalTasks) * 100)}%)</>
              )}
            </span>
            <span className={styles.statDivider}>·</span>
            <span className={styles.statItem}>
              <strong>Bingos:</strong>{' '}
              {selectedBoard.linesCompleted > 0
                ? `${selectedBoard.linesCompleted} (${(selectedBoard.completedLineIds ?? []).join(', ')})`
                : 'None yet'}
            </span>
            <span className={styles.statDivider}>·</span>
            <span className={styles.statItem}>
              <strong>Status:</strong>{' '}
              <span className={`${styles.statusBadge} ${statusBadgeClass(selectedBoard.status as BoardStatus)}`}>
                {statusLabel(selectedBoard.status as BoardStatus)}
              </span>
            </span>
          </div>
        </section>
      )}

      {/* ── Detail Modal (progress tasks) ── */}
      {selectedSquareId && (() => {
        const bt = boardTasks.find((b) => b.id === selectedSquareId);
        if (!bt || !selectedBoard) return null;
        const task = taskMap[bt.taskId];
        if (!task) return null;
        const squareData = taskToSquareData(task, allTaskSteps);
        const squareState = boardTaskToSquareState(bt);

        return (
          <DetailModal
            sq={squareData}
            state={squareState}
            onClose={() => setSelectedSquareId(null)}
            onToggleComplete={() => {
              void handleComplete(selectedBoard.id, bt.id, {
                isCompleted: !bt.isCompleted,
              });
            }}
            onIncrementCount={() => {
              void handleComplete(selectedBoard.id, bt.id, {
                currentCount: (bt.currentCount ?? 0) + 1,
              });
            }}
            onDecrementCount={() => {
              const prev = bt.currentCount ?? 0;
              if (prev > 0) {
                void handleComplete(selectedBoard.id, bt.id, {
                  currentCount: prev - 1,
                });
              }
            }}
            onToggleStep={(stepId: string) => {
              const current = new Set(bt.completedStepIds ?? []);
              if (current.has(stepId)) {
                current.delete(stepId);
              } else {
                current.add(stepId);
              }
              void handleComplete(selectedBoard.id, bt.id, {
                completedStepIds: Array.from(current),
              });
            }}
          />
        );
      })()}

      {/* ── Floating Context Menu ── */}
      {contextMenu && selectedBoard && (() => {
        const bt = boardTasks.find((b) => b.id === contextMenu.squareId);
        if (!bt) return null;
        const task = taskMap[bt.taskId];
        if (!task) return null;
        const squareData = taskToSquareData(task, allTaskSteps);
        const squareState = boardTaskToSquareState(bt);

        return (
          <FloatingContextMenu
            sq={squareData}
            state={squareState}
            position={{ x: contextMenu.x, y: contextMenu.y }}
            onClose={() => setContextMenu(null)}
            onToggleComplete={() => {
              void handleComplete(selectedBoard.id, bt.id, { isCompleted: !bt.isCompleted });
              setContextMenu(null);
            }}
            onIncrementCount={() => {
              void handleComplete(selectedBoard.id, bt.id, {
                currentCount: (bt.currentCount ?? 0) + 1,
              });
              setContextMenu(null);
            }}
            onDecrementCount={() => {
              const prev = bt.currentCount ?? 0;
              if (prev > 0) {
                void handleComplete(selectedBoard.id, bt.id, { currentCount: prev - 1 });
              }
              setContextMenu(null);
            }}
            onResetCount={() => {
              void handleComplete(selectedBoard.id, bt.id, { currentCount: 0, isCompleted: false });
              setContextMenu(null);
            }}
            onMarkAllStepsComplete={() => {
              const allStepIds = (squareData.steps ?? []).map((s) => s.id);
              void handleComplete(selectedBoard.id, bt.id, { completedStepIds: allStepIds });
              setContextMenu(null);
            }}
            onMarkAllStepsIncomplete={() => {
              void handleComplete(selectedBoard.id, bt.id, { completedStepIds: [] });
              setContextMenu(null);
            }}
            onViewDetails={() => {
              setSelectedSquareId(bt.id);
              setContextMenu(null);
            }}
          />
        );
      })()}
    </div>
  );
}
