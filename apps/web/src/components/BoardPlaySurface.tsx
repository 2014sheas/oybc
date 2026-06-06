import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  AchievementTrigger,
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  TaskType,
  isWithinTimeframe,
  type Board,
  type RecurringBoardTemplate,
  type TaskStep,
  type BoardTask,
} from '@oybc/shared';
import { useBoardTasks, useBoards, useRecurringBoardTemplates } from '../hooks';
import { useTaskLibrary } from '../pages/createPage/useTaskLibrary';
import { db } from '../db/database';
import { taskToSquareData, taskToSquareState } from '../db/adapters';
import { handleTaskCompletion, runBoardCascadeForTask } from '../db/operations/orchestration';
import { addToSyncQueue } from '../db/operations/syncQueue';
import { incrementSharedCounter } from '../db/operations/tasks';
import { updateBoardTaskAndCascade } from '../db/operations/boardTasks';
import {
  InteractiveTaskSquare,
  DetailModal,
  FloatingContextMenu,
  type AchievementSquareBadgeData,
} from './InteractiveTaskSquare';
import type { ContextMenuState } from './interactiveTaskSquareUtils';
import { CellSwapModal } from './CellSwapModal';
import { BoardStatusBadge } from './BoardStatusBadge';
import { TaskDetailSheet } from './TaskDetailSheet';
import { isBoardExpired } from '../utils/boardDisplayUtils';
import { formatDisplayDate } from '../utils/dateFormat';
import { EditBoardSheet } from './EditBoardSheet';
import { usePreferences } from '../hooks/usePreferences';
import styles from '../pages/BoardPlayPage.module.css';

// ─── Constants ────────────────────────────────────────────────────────────────

const FLASH_MS = 3000;

// Module-scoped frozen empty arrays. Reused as a stable fallback for
// `useLiveQuery(...) ?? FALLBACK` so React Compiler can preserve memoization
// of downstream useCallback/useMemo deps; an inline `?? []` re-allocates on
// every render and trips `react-hooks/preserve-manual-memoization`. Typed as
// the mutable element array because consumers (legacy step helpers) require
// `T[]`, not `readonly T[]`; the runtime frozen array still throws on mutation.
const EMPTY_BOARD_TASKS = Object.freeze([]) as unknown as BoardTask[];
const EMPTY_TASK_STEPS = Object.freeze([]) as unknown as TaskStep[];
// Phase 6.3 — frozen empty fallbacks for the workspace-wide board /
// template hooks. Same pattern as EMPTY_BOARD_TASKS above (preserves
// React Compiler memoization of downstream deps).
const EMPTY_BOARDS = Object.freeze([]) as unknown as Board[];
const EMPTY_TEMPLATES = Object.freeze([]) as unknown as RecurringBoardTemplate[];

// ─── Types ────────────────────────────────────────────────────────────────────

interface FlashMessage {
  text: string;
  variant: 'bingo' | 'greenlog';
}

export interface BoardPlaySurfaceProps {
  /** The resolved board to play. Never null/undefined — the container guards loading/not-found. */
  board: Board;
  /** Active user id, used for workspace-wide compound/achievement lookups. */
  userId: string | undefined;
  /** Chrome rendered at the very top of the container (back link on the
   *  plain page; the window bar in the pager). */
  header?: React.ReactNode;
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * BoardPlaySurface — presentational interactive bingo grid for a *resolved*
 * board. Owns task-completion orchestration, flash messages, the detail
 * modal, the floating context menu, and the library sheet. Consumed by
 * `BoardPlayPage` (the `/boards/:id` route) and `CoreBoardWindowPage`
 * (the per-window core-board pager). The `header` slot lets each consumer
 * supply its own top chrome.
 */
export function BoardPlaySurface({ board, userId, header }: BoardPlaySurfaceProps): React.ReactElement {
  const boardId = board.id;

  // ── Reactive data ──────────────────────────────────────────────────────

  const boardTasks = useBoardTasks(boardId) ?? EMPTY_BOARD_TASKS;
  // Post-unification, taskSteps was dropped in Dexie v5. The adapter still
  // accepts a steps array for the legacy progress branch, but every consumer
  // here passes EMPTY_TASK_STEPS — the live query was needlessly hitting a
  // deregistered store. The adapter's progress branch is itself dead code
  // post-migration; Phase 8 will remove it.

  // Compound resolution data (all BoardTasks workspace-wide for child lookup).
  const { taskMap, compoundChildrenByCompound } = useTaskLibrary(userId);

  // Workspace-wide BoardTask list for compound child toggle fallback.
  const allBoardTasks: BoardTask[] =
    useLiveQuery(() => db.boardTasks.toArray(), []) ?? EMPTY_BOARD_TASKS;

  // Phase 6.3 — workspace data needed by per-cell badge data computation
  // for ACHIEVEMENT-typed Tasks. Reuses existing hooks; `useBoards`
  // returns non-deleted boards for the user, and
  // `useRecurringBoardTemplates` returns non-deleted templates.
  const allBoards: Board[] = useBoards(userId) ?? EMPTY_BOARDS;
  const allTemplates: RecurringBoardTemplate[] =
    useRecurringBoardTemplates(userId) ?? EMPTY_TEMPLATES;

  // ── UI state ───────────────────────────────────────────────────────────

  const [flashMessage, setFlashMessage] = useState<FlashMessage | null>(null);
  const [selectedSquareId, setSelectedSquareId] = useState<string | null>(null);
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);
  const [openedTaskInLibrary, setOpenedTaskInLibrary] = useState<string | null>(null);
  const flashTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // M2 — edit-board sheet (ACTIVE boards only).
  const [editBoardOpen, setEditBoardOpen] = useState(false);
  // M3 — cell swap: the boardTaskId whose square the user requested a swap for.
  const [swapBoardTaskId, setSwapBoardTaskId] = useState<string | null>(null);

  // User preferences (for weekStartDay, used by EditBoardSheet).
  const [prefs] = usePreferences();

  // Clean up flash timer on unmount
  useEffect(() => {
    return () => { if (flashTimerRef.current) clearTimeout(flashTimerRef.current); };
  }, []);

  // ── Derived data ───────────────────────────────────────────────────────

  // Phase 6.3 — per-cell achievement-task badge data, keyed by
  // BoardTask.id. The badge labels what each ACHIEVEMENT-typed Task is
  // watching; the cell's actual completion state still comes from
  // derivationPass.
  //
  // Build the lookup maps once per render (boardById, spawnsByTemplate)
  // then loop cells to assemble the badge entries. This mirrors the
  // performance optimization in `derivationPass.ts` — without the
  // template index, each template-mode cell would re-scan all boards.
  const achievementBadgesByBoardTaskId = useMemo<Record<string, AchievementSquareBadgeData>>(() => {
    const out: Record<string, AchievementSquareBadgeData> = {};
    const boardById = new Map<string, Board>();
    const spawnsByTemplate = new Map<string, Board[]>();
    for (const b of allBoards) {
      if (b.isDeleted) continue;
      boardById.set(b.id, b);
      if (b.spawnedFromTemplateId) {
        const list = spawnsByTemplate.get(b.spawnedFromTemplateId) ?? [];
        list.push(b);
        spawnsByTemplate.set(b.spawnedFromTemplateId, list);
      }
    }
    const templateById = new Map(allTemplates.map((t) => [t.id, t]));

    for (const bt of boardTasks) {
      const t = taskMap[bt.taskId];
      if (!t || t.type !== TaskType.ACHIEVEMENT) continue;
      const trigger = t.achievementTrigger ?? AchievementTrigger.GREENLOG;
      const meets = (b: Board): boolean =>
        trigger === AchievementTrigger.BINGO
          ? (b.linesCompleted ?? 0) > 0
          : b.status === BoardStatus.COMPLETED;
      // Phase 6.3 precedence: referencedBoardId wins when both fields
      // somehow get set. The Zod refinement should prevent this, but
      // the badge stays predictable for bad-data payloads.
      if (t.referencedBoardId) {
        const ref = boardById.get(t.referencedBoardId);
        out[bt.id] = {
          mode: 'specificBoard',
          referencedBoardName: ref?.name,
          referencedBoardCompleted: ref ? meets(ref) : false,
        };
        continue;
      }
      if (t.referencedTemplateId) {
        const tmpl = templateById.get(t.referencedTemplateId);
        const spawns = spawnsByTemplate.get(t.referencedTemplateId) ?? [];
        // Parse to timestamps via the shared helper — `Board.startDate`/
        // `endDate` may be local-ISO (no zone) or UTC-with-`Z` (sync
        // round-trips), and the two encodings don't compare correctly
        // as strings. Same fix as derivationPass.ts.
        const inWindow = spawns.filter((b) =>
          isWithinTimeframe(b.startDate, board.startDate, board.endDate),
        );
        const met = inWindow.filter(meets).length;
        out[bt.id] = {
          mode: 'recurringTemplate',
          templateName: tmpl?.name,
          templateInWindowMet: met,
          templateRequiredCount: t.requiredCount ?? 0,
        };
      }
      // No reference set on an ACHIEVEMENT task: skip the badge entirely
      // (the cell renders as a regular task; derivation marks incomplete).
    }
    return out;
  }, [boardTasks, allBoards, allTemplates, taskMap, board.startDate, board.endDate]);

  // Phase 3 — Shared Counters: Set of task ids that are shared-counter SOURCES
  // (i.e., at least one other task points to them via `sharedCounterId`).
  // Computed once per render from taskMap so the grid `onAct` can detect
  // whether tapping a counting task should route through incrementSharedCounter.
  const sharedCounterSourceIds = useMemo<Set<string>>(() => {
    const sources = new Set<string>();
    for (const t of Object.values(taskMap)) {
      if (t.sharedCounterId) sources.add(t.sharedCounterId);
    }
    return sources;
  }, [taskMap]);

  const sortedBoardTasks = [...boardTasks].sort((a, b) =>
    a.row !== b.row ? a.row - b.row : a.col - b.col
  );

  const gridSize = board.boardSize ?? 3;

  const btByPosition: Record<string, BoardTask> = {};
  for (const bt of sortedBoardTasks) {
    btByPosition[`${bt.row}-${bt.col}`] = bt;
  }

  const isExpired = isBoardExpired(board);

  // ── Flash message helper ───────────────────────────────────────────────

  // Wrapped in useCallback so the function reference is stable across
  // renders. `flashTimerRef` is a stable ref so empty deps is correct.
  // The body writes the ref's `current` to track the active setTimeout
  // handle for cleanup — the `react-hooks/refs` rule
  // (eslint-plugin-react-hooks v7.1+) is conservative about ref access
  // chains; useCallback makes the function's role explicit (event-time,
  // never during render) so the analyzer doesn't flag the call sites.
  const showFlash = useCallback((text: string, variant: FlashMessage['variant']): void => {
    if (flashTimerRef.current) clearTimeout(flashTimerRef.current);
    const msg = { text, variant };
    setFlashMessage(msg);
    flashTimerRef.current = setTimeout(() => {
      setFlashMessage((current) => current === msg ? null : current);
    }, FLASH_MS);
  }, []);

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
      if (!boardId) return;
      try {
        const result = await handleTaskCompletion(boardId, boardTaskId, updates);
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

    [boardId, showFlash]
  );

  /**
   * Phase 3 — Shared Counters: increment the shared-counter accumulator for a
   * given source task id, then show any bingo/greenlog flash that resulted.
   *
   * Used when the tapped/clicked task is either:
   *   (a) the source (template) counting task itself, or
   *   (b) a linked (derived) counting task whose `sharedCounterId` points to
   *       the source.
   *
   * Both cases route to `incrementSharedCounter(sourceId)` which handles the
   * full propagation transactionally (source update → linked task re-derive →
   * cascade for all affected boards).
   *
   * Post-increment bingo/greenlog flash: we re-fetch the board after the
   * transaction and compare stats against the pre-increment snapshot.
   * Flash is best-effort — a query failure doesn't undo the write.
   *
   * @param sourceTaskId - The source (template) task id to increment.
   */
  const handleSharedCounterIncrement = useCallback(
    async (sourceTaskId: string): Promise<void> => {
      if (isExpired) return;
      try {
        // Capture the pre-increment board stats for flash comparison.
        const boardBefore = await db.boards.get(boardId);
        await incrementSharedCounter(sourceTaskId);
        // Re-fetch to get post-increment board state.
        const boardAfter = await db.boards.get(boardId);
        if (!boardBefore || !boardAfter) return;

        const prevBingos = new Set(boardBefore.completedLineIds ?? []);
        const nextBingos = new Set(boardAfter.completedLineIds ?? []);
        const newBingos = [...nextBingos].filter((id) => !prevBingos.has(id));
        const lostBingos = [...prevBingos].filter((id) => !nextBingos.has(id));
        const totalSquares = boardAfter.boardSize * boardAfter.boardSize;
        const isGreenlog = boardAfter.completedTasks >= totalSquares;
        const wasActive = boardBefore.status === BoardStatus.ACTIVE;
        const isNowCompleted = boardAfter.status === BoardStatus.COMPLETED;
        const wasCompleted = boardBefore.status === BoardStatus.COMPLETED;
        const isNowActive = boardAfter.status === BoardStatus.ACTIVE;

        if (wasCompleted && isNowActive) {
          showFlash('Board reactivated — no longer complete', 'bingo');
        } else if (lostBingos.length > 0) {
          showFlash(`Bingo lost: ${lostBingos.join(', ')}`, 'bingo');
        } else if (wasActive && isNowCompleted && isGreenlog) {
          showFlash('GREENLOG! Board complete!', 'greenlog');
        } else if (newBingos.length > 0) {
          showFlash(`Bingo! ${newBingos.join(', ')}`, 'bingo');
        }
      } catch (err) {
        console.error('Shared counter increment failed:', err);
        showFlash('Something went wrong', 'bingo');
      }
    },
    [boardId, isExpired, showFlash],
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
        // bingo state + denormalised board stats. Wrap the Task update + sync
        // enqueue + cascade in a single Dexie transaction so a downstream
        // failure rolls back the partial writes; previously a crash between
        // the task update and the cascade would leave the Task flipped but
        // board stats stale forever.
        try {
          const now = new Date().toISOString();
          await db.transaction(
            'rw',
            [db.tasks, db.boards, db.boardTasks, db.compoundChildren, db.syncQueue],
            async () => {
              await db.tasks.update(childTaskId, {
                isCompleted: !childTask.isCompleted,
                completedAt: !childTask.isCompleted ? now : undefined,
                updatedAt: now,
                version: childTask.version + 1,
              });
              const updated = await db.tasks.get(childTaskId);
              if (updated) {
                await addToSyncQueue('tasks', childTaskId, SyncOperationType.UPDATE, updated);
              }
              await runBoardCascadeForTask(childTaskId);
            },
          );
        } catch (err) {
          console.error('Compound child toggle failed:', err);
          showFlash('Something went wrong', 'bingo');
        }
      }
    },
    [isExpired, taskMap, boardTasks, allBoardTasks, handleComplete, showFlash]
  );

  // ── Render ─────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      {header}

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

      {/* Play header */}
      <div className={styles.playHeader}>
        <div className={styles.playHeaderLeft}>
          <span className={styles.nowPlaying}>Now Playing</span>
          <h2 className={styles.playBoardName}>{board.name}</h2>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
          <BoardStatusBadge status={board.status} />
          {/* M2 — edit button only on ACTIVE boards (DRAFT uses wizard; COMPLETED/ARCHIVED are immutable). */}
          {board.status === BoardStatus.ACTIVE && (
            <button
              type="button"
              onClick={() => setEditBoardOpen(true)}
              aria-label="Edit board"
              title="Edit board"
              style={{
                padding: '4px 10px',
                fontSize: '0.8rem',
                fontWeight: 600,
                background: 'var(--bg-secondary)',
                border: '1px solid var(--border-color)',
                borderRadius: '6px',
                cursor: 'pointer',
                color: 'var(--text-secondary)',
                lineHeight: 1.4,
              }}
            >
              Edit
            </button>
          )}
        </div>
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
                  task, EMPTY_TASK_STEPS, taskChildren, taskMap, compoundChildrenByCompound,
                );
                const squareState = taskToSquareState(
                  task, taskChildren, taskMap, compoundChildrenByCompound,
                );
                const taskIsCompleted = squareState.isCompleted;
                // Use squareState.currentCount (baseline-adjusted for linked
                // counters). For standalone counters this equals task.currentCount.
                const taskCurrentCount = squareState.currentCount;

                cells.push(
                  <InteractiveTaskSquare
                    key={bt.id}
                    sq={squareData}
                    state={squareState}
                    achievementBadge={achievementBadgesByBoardTaskId[bt.id]}
                    onAct={() => {
                      if (isExpired) return;
                      if (squareData.type === 'progress' || squareData.type === 'compound') {
                        setSelectedSquareId(bt.id);
                      } else if (squareData.type === 'counting') {
                        // Phase 3 — Shared Counters routing:
                        //  (a) Linked derived counter (task.sharedCounterId != null):
                        //      tap increments the source task, propagates to all siblings.
                        //  (b) Source counter (task.id in sharedCounterSourceIds):
                        //      tap increments source + propagates to all linked tasks.
                        //  (c) Standalone counter (no shared link at all):
                        //      falls through to the legacy handleComplete path.
                        // All shared-counter paths forbid the old high-end clamp (overshoot allowed).
                        if (task.sharedCounterId != null) {
                          void handleSharedCounterIncrement(task.sharedCounterId);
                        } else if (sharedCounterSourceIds.has(task.id)) {
                          void handleSharedCounterIncrement(task.id);
                        } else {
                          // Standalone (unlinked) counting task — no propagation needed.
                          const next = taskCurrentCount + 1;
                          void handleComplete(bt.id, { currentCount: next });
                        }
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
          task, EMPTY_TASK_STEPS, taskChildren, taskMap, compoundChildrenByCompound,
        );
        const squareState = taskToSquareState(
          task, taskChildren, taskMap, compoundChildrenByCompound,
        );
        // Use squareState.currentCount (baseline-adjusted for linked counters)
        // rather than the raw task.currentCount accumulator. For standalone
        // counters the two values are identical; for linked derived counters
        // taskToSquareState has already applied deriveDisplayedCount.
        const modalCurrentCount = squareState.currentCount;
        // Linked derived counters are read-only: their value is driven by the
        // source task. Decrement and reset must be disabled for them.
        const isLinkedCounter = squareData.sharedCounterId != null;

        return (
          <DetailModal
            sq={squareData}
            state={squareState}
            onClose={() => setSelectedSquareId(null)}
            onToggleComplete={() => {
              if (isExpired) return;
              // `handleComplete` transitively calls `showFlash`, which
              // writes `flashTimerRef.current`. The `react-hooks/refs`
              // rule (v7.1+) traces that ref-access chain and flags this
              // call site as "ref accessed during render" — but this
              // callback is the DetailModal's onToggleComplete prop,
              // invoked from the modal's click handler well after
              // render commits. False positive; disabled per-site.
              // eslint-disable-next-line react-hooks/refs
              void handleComplete(bt.id, { isCompleted: !squareState.isCompleted });
            }}
            onIncrementCount={() => {
              if (isExpired) return;
              // Phase 3 — Shared Counters: same routing as the grid onAct.
              // handleSharedCounterIncrement transitively writes flashTimerRef.current
              // from showFlash — same false-positive as the handleComplete case above.
              /* eslint-disable react-hooks/refs */
              if (task.sharedCounterId != null) {
                void handleSharedCounterIncrement(task.sharedCounterId);
              } else if (sharedCounterSourceIds.has(task.id)) {
                void handleSharedCounterIncrement(task.id);
              } else {
                void handleComplete(bt.id, { currentCount: modalCurrentCount + 1 });
              }
              /* eslint-enable react-hooks/refs */
            }}
            onDecrementCount={() => {
              // Linked derived counters are read-only — decrement must go through
              // the source. Silently ignore the action here; the UI should hide/
              // disable the button when isLinkedCounter is true.
              if (isExpired || isLinkedCounter) return;
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
            onOpenInLibrary={(taskId) => setOpenedTaskInLibrary(taskId)}
          />
        );
      })()}

      {/* Task library sheet — "Open in library" from context menu or compound child rows */}
      <TaskDetailSheet
        taskId={openedTaskInLibrary}
        onClose={() => setOpenedTaskInLibrary(null)}
        onOpenTask={(id) => setOpenedTaskInLibrary(id)}
      />

      {/* M2 — Edit board sheet (ACTIVE boards only). */}
      {editBoardOpen && (
        <EditBoardSheet
          board={board.status === BoardStatus.ACTIVE ? board : null}
          weekStartDay={prefs.weekStartDay}
          onClose={() => setEditBoardOpen(false)}
        />
      )}

      {/* Floating Context Menu */}
      {contextMenu && (() => {
        const bt = boardTasks.find((b) => b.id === contextMenu.squareId);
        if (!bt) return null;
        const task = taskMap[bt.taskId];
        if (!task) return null;
        const taskChildren = compoundChildrenByCompound[task.id] ?? [];
        const squareData = taskToSquareData(
          task, EMPTY_TASK_STEPS, taskChildren, taskMap, compoundChildrenByCompound,
        );
        const squareState = taskToSquareState(
          task, taskChildren, taskMap, compoundChildrenByCompound,
        );
        // Use squareState.currentCount (baseline-adjusted for linked counters).
        const menuCurrentCount = squareState.currentCount;
        // Linked derived counters are read-only — decrement/reset must be gated.
        const isLinkedCounter = squareData.sharedCounterId != null;

        // M3 — Swap is only available on ACTIVE non-expired, non-center squares.
        const swapEligible =
          board.status === BoardStatus.ACTIVE && !isExpired && !bt.isCenter;

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
              // Phase 3 — Shared Counters: same routing as the grid onAct.
              if (task.sharedCounterId != null) {
                void handleSharedCounterIncrement(task.sharedCounterId);
              } else if (sharedCounterSourceIds.has(task.id)) {
                void handleSharedCounterIncrement(task.id);
              } else {
                void handleComplete(bt.id, { currentCount: menuCurrentCount + 1 });
              }
              setContextMenu(null);
            }}
            onDecrementCount={() => {
              // Linked derived counters are read-only — no decrement.
              if (isLinkedCounter) { setContextMenu(null); return; }
              if (menuCurrentCount > 0) {
                void handleComplete(bt.id, { currentCount: menuCurrentCount - 1 });
              }
              setContextMenu(null);
            }}
            onResetCount={() => {
              // Linked derived counters are read-only — no reset.
              if (isLinkedCounter) { setContextMenu(null); return; }
              void handleComplete(bt.id, { currentCount: 0, isCompleted: false });
              setContextMenu(null);
            }}
            onViewDetails={() => {
              setSelectedSquareId(bt.id);
              setContextMenu(null);
            }}
            onOpenInLibrary={(taskId) => {
              setOpenedTaskInLibrary(taskId);
              setContextMenu(null);
            }}
            onSwapTask={swapEligible ? () => {
              setSwapBoardTaskId(bt.id);
              setContextMenu(null);
            } : undefined}
          />
        );
      })()}

      {/* M3 — Cell Swap Modal */}
      {swapBoardTaskId && (() => {
        const bt = boardTasks.find((b) => b.id === swapBoardTaskId);
        if (!bt) return null;
        return (
          <CellSwapModal
            currentTaskId={bt.taskId}
            candidateTasks={Object.values(taskMap)}
            onClose={() => setSwapBoardTaskId(null)}
            onConfirm={async (newTaskId) => {
              setSwapBoardTaskId(null);
              try {
                await updateBoardTaskAndCascade(swapBoardTaskId, newTaskId);
              } catch (err) {
                console.error('Cell swap failed:', err);
                // `showFlash` is a stable event-time callback; the ref access
                // happens inside a catch block (not during render). False positive
                // from the react-hooks/refs analyzer — same pattern as the
                // DetailModal `onToggleComplete` disable above.
                // eslint-disable-next-line react-hooks/refs
                showFlash('Swap failed — please try again', 'bingo');
              }
            }}
          />
        );
      })()}
    </div>
  );
}
