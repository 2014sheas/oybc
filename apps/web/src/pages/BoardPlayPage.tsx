import { useState, useCallback, useRef, useEffect } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  CenterSquareType,
  type TaskStep,
  type Task,
  type BoardTask,
} from '@oybc/shared';
import { useAuth } from '../firebase/AuthContext';
import { useBoard, useBoardTasks, useTasks } from '../hooks';
import { db } from '../db/database';
import { taskToSquareData, boardTaskToSquareState } from '../db/adapters';
import { handleTaskCompletion } from '../db/operations/orchestration';
import {
  InteractiveTaskSquare,
  DetailModal,
  FloatingContextMenu,
  type ContextMenuState,
} from '../components/InteractiveTaskSquare';
import { BoardStatusBadge } from '../components/BoardStatusBadge';
import { isBoardExpired } from '../utils/boardDisplayUtils';
import styles from './BoardPlayPage.module.css';

// ─── Constants ────────────────────────────────────────────────────────────────

const FLASH_MS = 3000;

// ─── Types ────────────────────────────────────────────────────────────────────

interface FlashMessage {
  text: string;
  variant: 'bingo' | 'greenlog';
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * BoardPlayPage — Full-screen interactive bingo grid.
 *
 * Renders the bingo board for a selected board, handling task completion,
 * bingo detection with flash messages, and board status transitions.
 * All interactions go through `handleTaskCompletion()` for atomic orchestration.
 */
export function BoardPlayPage(): React.ReactElement {
  const { id } = useParams<{ id: string }>();
  const { user } = useAuth();

  // ── Reactive data ──────────────────────────────────────────────────────

  // undefined = still loading, null = resolved but not found, Board = found
  const boardQuery = useBoard(id);
  const board = boardQuery === undefined ? undefined : (boardQuery ?? null);
  const boardTasks = useBoardTasks(id) ?? [];
  const allTasks = useTasks(user?.id) ?? [];
  const allTaskSteps: TaskStep[] =
    useLiveQuery(
      () => db.taskSteps.filter((s: TaskStep) => !s.isDeleted).toArray(),
      []
    ) ?? [];

  // ── UI state ───────────────────────────────────────────────────────────

  const [flashMessage, setFlashMessage] = useState<FlashMessage | null>(null);
  const [selectedSquareId, setSelectedSquareId] = useState<string | null>(null);
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);
  const flashTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Clean up flash timer on unmount
  useEffect(() => {
    return () => { if (flashTimerRef.current) clearTimeout(flashTimerRef.current); };
  }, []);

  // ── Derived data ───────────────────────────────────────────────────────

  const taskMap: Record<string, Task> = {};
  for (const t of allTasks) taskMap[t.id] = t;

  const sortedBoardTasks = [...boardTasks].sort((a, b) =>
    a.row !== b.row ? a.row - b.row : a.col - b.col
  );

  const gridSize = board?.boardSize ?? 3;

  const btByPosition: Record<string, BoardTask> = {};
  for (const bt of sortedBoardTasks) {
    btByPosition[`${bt.row}-${bt.col}`] = bt;
  }

  const isExpired = board ? isBoardExpired(board) : false;

  // ── Flash message helper ───────────────────────────────────────────────

  function showFlash(text: string, variant: FlashMessage['variant']): void {
    if (flashTimerRef.current) clearTimeout(flashTimerRef.current);
    const msg = { text, variant };
    setFlashMessage(msg);
    flashTimerRef.current = setTimeout(() => {
      setFlashMessage((current) => current === msg ? null : current);
    }, FLASH_MS);
  }

  // ── Completion handler ─────────────────────────────────────────────────

  /**
   * Handles task completion via the orchestration layer, then shows
   * appropriate flash messages based on bingo detection results.
   */
  const handleComplete = useCallback(
    async (
      boardTaskId: string,
      updates: {
        isCompleted?: boolean;
        currentCount?: number;
        completedStepIds?: string[];
      }
    ): Promise<void> => {
      if (!id) return;
      try {
        const result = await handleTaskCompletion(id, boardTaskId, updates);
        // Priority: reactivated > lostBingos > greenlog > newBingos
        if (result.boardReactivated) {
          showFlash('Board reactivated — no longer complete', 'bingo');
        } else if (result.lostBingos.length > 0) {
          showFlash(`Bingo lost: ${result.lostBingos.join(', ')}`, 'bingo');
        } else if (result.isGreenlog) {
          showFlash('GREENLOG! Board complete!', 'greenlog');
        } else if (result.newBingos.length > 0) {
          showFlash(`Bingo! ${result.newBingos.join(', ')}`, 'bingo');
        }
      } catch (err) {
        console.error('Task completion failed:', err);
        showFlash('Something went wrong', 'bingo');
        setContextMenu(null);
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [id]
  );

  // ── Board not found ────────────────────────────────────────────────────

  // undefined = still loading (Dexie resolving), null = not found
  if (board === undefined) {
    return (
      <div className={styles.container}>
        <p className={styles.emptyState}>Loading...</p>
      </div>
    );
  }

  if (board === null) {
    return (
      <div className={styles.container}>
        <Link to="/boards" className={styles.backLink}>&larr; Back to boards</Link>
        <div className={styles.notFound}>
          <p>Board not found</p>
        </div>
      </div>
    );
  }

  // ── Render ─────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      {/* Flash message */}
      {flashMessage && (
        <div
          className={`${styles.flashMessage} ${flashMessage.variant === 'greenlog' ? styles.flashGreenlog : styles.flashBingo}`}
          role="status"
          aria-live="polite"
        >
          {flashMessage.text}
        </div>
      )}

      {/* Back link */}
      <Link to="/boards" className={styles.backLink}>&larr; Back to boards</Link>

      {/* Play header */}
      <div className={styles.playHeader}>
        <div className={styles.playHeaderLeft}>
          <span className={styles.nowPlaying}>Now Playing</span>
          <h2 className={styles.playBoardName}>{board.name}</h2>
        </div>
        <BoardStatusBadge status={board.status} />
      </div>

      {/* Expired banner */}
      {isExpired && (
        <div className={styles.expiredBanner}>
          Board expired on {board.endDate?.split('T')[0] ?? 'unknown date'}
        </div>
      )}

      {/* Interactive grid */}
      {sortedBoardTasks.length === 0 ? (
        <p className={styles.emptyState}>Loading board tasks...</p>
      ) : (
        <div
          className={styles.playGrid}
          style={{ gridTemplateColumns: `repeat(${gridSize}, 90px)` }}
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
                  if (isCenter && (board.centerSquareType === CenterSquareType.FREE ||
                      board.centerSquareType === CenterSquareType.CUSTOM_FREE)) {
                    cells.push(
                      <div key={`center-${row}-${col}`} className={styles.freeSquare}>
                        FREE
                      </div>
                    );
                  } else {
                    cells.push(
                      <div key={`empty-${row}-${col}`} className={styles.emptySquare} />
                    );
                  }
                  continue;
                }

                const task = taskMap[bt.taskId];
                if (!task) {
                  cells.push(
                    <div key={`missing-${row}-${col}`} className={styles.emptySquare}>?</div>
                  );
                  continue;
                }

                const squareData = taskToSquareData(task, allTaskSteps);
                const squareState = boardTaskToSquareState(bt);

                cells.push(
                  <InteractiveTaskSquare
                    key={bt.id}
                    sq={squareData}
                    state={squareState}
                    onAct={() => {
                      if (isExpired) return;
                      if (squareData.type === 'progress') {
                        setSelectedSquareId(bt.id);
                      } else if (squareData.type === 'counting') {
                        const next = (bt.currentCount ?? 0) + 1;
                        if (squareData.maxCount && next > squareData.maxCount) return;
                        void handleComplete(bt.id, { currentCount: next });
                      } else {
                        void handleComplete(bt.id, {
                          isCompleted: !bt.isCompleted,
                        });
                      }
                    }}
                    onContextMenu={(e) => {
                      if (isExpired) return;
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

      {/* Stats bar */}
      <div className={styles.statsBar}>
        <span className={styles.statItem}>
          <strong>Progress:</strong>{' '}
          {board.completedTasks}/{board.totalTasks}
          {board.totalTasks > 0 && (
            <> ({Math.round((board.completedTasks / board.totalTasks) * 100)}%)</>
          )}
        </span>
        <span className={styles.statDivider}>·</span>
        <span className={styles.statItem}>
          <strong>Bingos:</strong>{' '}
          {board.linesCompleted > 0
            ? `${board.linesCompleted} (${(board.completedLineIds ?? []).join(', ')})`
            : 'None yet'}
        </span>
      </div>

      {/* Detail Modal (progress tasks) */}
      {selectedSquareId && (() => {
        const bt = boardTasks.find((b) => b.id === selectedSquareId);
        if (!bt) return null;
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
              if (isExpired) return;
              void handleComplete(bt.id, { isCompleted: !bt.isCompleted });
            }}
            onIncrementCount={() => {
              if (isExpired) return;
              void handleComplete(bt.id, { currentCount: (bt.currentCount ?? 0) + 1 });
            }}
            onDecrementCount={() => {
              if (isExpired) return;
              const prev = bt.currentCount ?? 0;
              if (prev > 0) {
                void handleComplete(bt.id, { currentCount: prev - 1 });
              }
            }}
            onToggleStep={(stepId: string) => {
              if (isExpired) return;
              const current = new Set(bt.completedStepIds ?? []);
              if (current.has(stepId)) {
                current.delete(stepId);
              } else {
                current.add(stepId);
              }
              void handleComplete(bt.id, { completedStepIds: Array.from(current) });
            }}
          />
        );
      })()}

      {/* Floating Context Menu */}
      {contextMenu && (() => {
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
              void handleComplete(bt.id, { isCompleted: !bt.isCompleted });
              setContextMenu(null);
            }}
            onIncrementCount={() => {
              void handleComplete(bt.id, { currentCount: (bt.currentCount ?? 0) + 1 });
              setContextMenu(null);
            }}
            onDecrementCount={() => {
              const prev = bt.currentCount ?? 0;
              if (prev > 0) {
                void handleComplete(bt.id, { currentCount: prev - 1 });
              }
              setContextMenu(null);
            }}
            onResetCount={() => {
              void handleComplete(bt.id, { currentCount: 0, isCompleted: false });
              setContextMenu(null);
            }}
            onMarkAllStepsComplete={() => {
              const allStepIds = (squareData.steps ?? []).map((s) => s.id);
              void handleComplete(bt.id, { completedStepIds: allStepIds });
              setContextMenu(null);
            }}
            onMarkAllStepsIncomplete={() => {
              void handleComplete(bt.id, { completedStepIds: [] });
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
