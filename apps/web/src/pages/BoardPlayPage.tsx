import { useState, useCallback, useRef, useEffect } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  CenterSquareType,
  SyncOperationType,
  type TaskStep,
  type BoardTask,
} from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useBoard, useBoardTasks } from '../hooks';
import { useTaskLibrary } from './createPage/useTaskLibrary';
import { db } from '../db/database';
import { taskToSquareData, taskToSquareState } from '../db/adapters';
import { handleTaskCompletion, runBoardCascadeForTask } from '../db/operations/orchestration';
import { addToSyncQueue } from '../db/operations/syncQueue';
import {
  InteractiveTaskSquare,
  DetailModal,
  FloatingContextMenu,
} from '../components/InteractiveTaskSquare';
import type { ContextMenuState } from '../components/interactiveTaskSquareUtils';
import { BoardStatusBadge } from '../components/BoardStatusBadge';
import { isBoardExpired } from '../utils/boardDisplayUtils';
import { formatDisplayDate } from '../utils/dateFormat';
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
  const allTaskSteps: TaskStep[] =
    useLiveQuery(
      () => db.taskSteps.filter((s: TaskStep) => !s.isDeleted).toArray(),
      []
    ) ?? [];

  // Compound resolution data (all BoardTasks workspace-wide for child lookup).
  const { taskMap, compoundChildrenByCompound } = useTaskLibrary(user?.id);

  // Workspace-wide BoardTask list for compound child toggle fallback.
  const allBoardTasks: BoardTask[] =
    useLiveQuery(() => db.boardTasks.toArray(), []) ?? [];

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

  // taskMap is provided by useTaskLibrary — no need to rebuild it here.

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

    [id]
  );

  /**
   * Handles toggling a compound child task from the detail sheet.
   *
   * Looks up the child's BoardTask on any board and delegates to
   * `handleTaskCompletion` so the global Task update and cross-board cascade
   * run atomically. If the child isn't placed on any board, falls back to a
   * direct Task update via the orchestration layer using its own BoardTask
   * id (or bails out gracefully).
   */
  const handleCompoundChildToggle = useCallback(
    async (childTaskId: string): Promise<void> => {
      if (isExpired) return;
      const childTask = taskMap[childTaskId];
      if (!childTask) return;

      // Find any BoardTask for this child Task on the current board first,
      // then fall back to any board in the workspace.
      const childBt =
        boardTasks.find((bt) => bt.taskId === childTaskId) ??
        allBoardTasks.find((bt) => bt.taskId === childTaskId);

      if (childBt) {
        await handleComplete(childBt.id, { isCompleted: !childTask.isCompleted });
      } else {
        // Child is not placed on any board, but the parent compound (on THIS
        // board, since the user is opening its detail sheet) still derives
        // through this child — so we must run the board cascade to recompute
        // bingo state + denormalised board stats.
        try {
          const now = new Date().toISOString();
          await db.tasks.update(childTaskId, {
            isCompleted: !childTask.isCompleted,
            completedAt: !childTask.isCompleted ? now : undefined,
            updatedAt: now,
            version: childTask.version + 1,
          });
          // Enqueue sync so the toggle propagates to other devices.
          // Mirrors the iOS fallback path which calls SyncQueueItem.save after updating.
          const updated = await db.tasks.get(childTaskId);
          if (updated) {
            void addToSyncQueue('tasks', childTaskId, SyncOperationType.UPDATE, updated);
          }
          // Run cross-board derivation so every board containing a compound
          // that transitively references this child gets stats + bingo
          // recomputed. Mirrors iOS handleCompoundChildToggle Path B.
          await runBoardCascadeForTask(childTaskId);
        } catch (err) {
          console.error('Compound child toggle failed:', err);
          showFlash('Something went wrong', 'bingo');
        }
      }
    },
    [isExpired, taskMap, boardTasks, allBoardTasks, handleComplete]
  );

  // ── Board not found ────────────────────────────────────────────────────

  // undefined = still loading (Dexie resolving), null = not found
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
          Board expired on {board.endDate ? formatDisplayDate(board.endDate) : 'unknown date'}
        </div>
      )}

      {/* Interactive grid */}
      {sortedBoardTasks.length === 0 ? (
        <p className={styles.emptyState}>Loading board tasks…</p>
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

                const taskChildren = compoundChildrenByCompound[task.id] ?? [];
                const squareData = taskToSquareData(
                  task, allTaskSteps, taskChildren, taskMap, compoundChildrenByCompound,
                );
                const squareState = taskToSquareState(
                  task, taskChildren, taskMap, compoundChildrenByCompound,
                );
                const taskIsCompleted = squareState.isCompleted;
                const taskCurrentCount = task.currentCount ?? 0;

                cells.push(
                  <InteractiveTaskSquare
                    key={bt.id}
                    sq={squareData}
                    state={squareState}
                    onAct={() => {
                      if (isExpired) return;
                      if (squareData.type === 'progress' || squareData.type === 'compound') {
                        setSelectedSquareId(bt.id);
                      } else if (squareData.type === 'counting') {
                        const next = taskCurrentCount + 1;
                        if (squareData.maxCount && next > squareData.maxCount) return;
                        void handleComplete(bt.id, { currentCount: next });
                      } else {
                        void handleComplete(bt.id, {
                          isCompleted: !taskIsCompleted,
                        });
                      }
                    }}
                    onContextMenu={(e) => {
                      if (isExpired) return;
                      setContextMenu({ squareId: bt.id, x: e.clientX, y: e.clientY });
                    }}
                    onCompoundChildToggle={
                      squareData.type === 'compound' ? handleCompoundChildToggle : undefined
                    }
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

      {/* Detail Modal (progress / compound tasks) */}
      {selectedSquareId && (() => {
        const bt = boardTasks.find((b) => b.id === selectedSquareId);
        if (!bt) return null;
        const task = taskMap[bt.taskId];
        if (!task) return null;
        const taskChildren = compoundChildrenByCompound[task.id] ?? [];
        const squareData = taskToSquareData(
          task, allTaskSteps, taskChildren, taskMap, compoundChildrenByCompound,
        );
        const squareState = taskToSquareState(
          task, taskChildren, taskMap, compoundChildrenByCompound,
        );
        const modalCurrentCount = task.currentCount ?? 0;

        return (
          <DetailModal
            sq={squareData}
            state={squareState}
            onClose={() => setSelectedSquareId(null)}
            onToggleComplete={() => {
              if (isExpired) return;
              void handleComplete(bt.id, { isCompleted: !squareState.isCompleted });
            }}
            onIncrementCount={() => {
              if (isExpired) return;
              void handleComplete(bt.id, { currentCount: modalCurrentCount + 1 });
            }}
            onDecrementCount={() => {
              if (isExpired) return;
              if (modalCurrentCount > 0) {
                void handleComplete(bt.id, { currentCount: modalCurrentCount - 1 });
              }
            }}
            onToggleStep={(stepId: string) => {
              if (isExpired) return;
              // Per-board step completion is not tracked under the unified model.
              // Progress steps link to their own Task records; toggle them directly.
              void handleCompoundChildToggle(stepId);
            }}
            onCompoundChildToggle={
              squareData.type === 'compound' ? handleCompoundChildToggle : undefined
            }
          />
        );
      })()}

      {/* Floating Context Menu */}
      {contextMenu && (() => {
        const bt = boardTasks.find((b) => b.id === contextMenu.squareId);
        if (!bt) return null;
        const task = taskMap[bt.taskId];
        if (!task) return null;
        const taskChildren = compoundChildrenByCompound[task.id] ?? [];
        const squareData = taskToSquareData(
          task, allTaskSteps, taskChildren, taskMap, compoundChildrenByCompound,
        );
        const squareState = taskToSquareState(
          task, taskChildren, taskMap, compoundChildrenByCompound,
        );
        const menuCurrentCount = task.currentCount ?? 0;

        return (
          <FloatingContextMenu
            sq={squareData}
            state={squareState}
            position={{ x: contextMenu.x, y: contextMenu.y }}
            onClose={() => setContextMenu(null)}
            onToggleComplete={() => {
              void handleComplete(bt.id, { isCompleted: !squareState.isCompleted });
              setContextMenu(null);
            }}
            onIncrementCount={() => {
              void handleComplete(bt.id, { currentCount: menuCurrentCount + 1 });
              setContextMenu(null);
            }}
            onDecrementCount={() => {
              if (menuCurrentCount > 0) {
                void handleComplete(bt.id, { currentCount: menuCurrentCount - 1 });
              }
              setContextMenu(null);
            }}
            onResetCount={() => {
              void handleComplete(bt.id, { currentCount: 0, isCompleted: false });
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
