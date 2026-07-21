import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AchievementTrigger,
  BoardStatus,
  CenterSquareType,
  TaskType,
  generateCounterTaskTitle,
  type Board,
  type Task,
  type TaskStep,
} from '@oybc/shared';
import {
  useBoardPlayData,
  useBoardPlay,
  useCounterArrivals,
  type FlashVariant,
  type CreditedToast,
} from '../hooks';
import { taskToSquareData, taskToSquareState } from '../db/adapters';
import {
  DetailModal,
  FloatingContextMenu,
} from './InteractiveTaskSquare';
import type { ContextMenuState } from './interactiveTaskSquareUtils';
import {
  resolveSharedCounterDefaultAmount,
  resolveSharedCounterSourceId,
} from './boardPlaySharedCounterUtils';
import { buildBoardQuickAmountOptions, parseCustomLogAmount } from './counters/amountChips';
import { undoLastCounterLog } from '../db/operations/tasks';
import { CellSwapModal } from './CellSwapModal';
import { BoardStatusBadge } from './BoardStatusBadge';
import { RecurringBadge } from './RecurringBadge';
import { TaskDetailSheet } from './TaskDetailSheet';
import { formatDisplayDate } from '../utils/dateFormat';
import { BoardEditPanel } from './boardEdit/BoardEditPanel';
import { ArrangeGrid } from './boardEdit/ArrangeGrid';
import { SquareTapMenu } from './boardEdit/SquareTapMenu';
import { BoardEditTaskSheet } from './boardEdit/BoardEditTaskSheet';
import { usePreferences } from '../hooks/usePreferences';
import { useNavigate } from 'react-router-dom';
import { compactStreakLabel, computeStreak, getHighlightedSquares } from '@oybc/shared';
import { getExpiryLabel } from '../utils/boardDisplayUtils';
import { RisoIcon } from './riso';
import { RisoBoardCell, type BoardCellModel } from './board/RisoBoardCell';
import { RisoBingoToast } from './play/RisoBingoToast';
import { RisoGreenlog } from './play/RisoGreenlog';
import { CounterLogToast } from './counters/CounterLogToast';
import { RisoArrivalBanner } from './play/RisoArrivalBanner';
import { ShareBoardSheet } from './share/ShareBoardSheet';
import styles from '../pages/BoardPlayPage.module.css';
import play from './play/Play.module.css';

// ─── Constants ────────────────────────────────────────────────────────────────

const FLASH_MS = 3000;

/**
 * Core timeframes that carry a streak. Used to gate the share poster's
 * STREAK stat — CUSTOM / INDEFINITE boards have no streak. The label itself
 * is formatted by the shared `compactStreakLabel` so the suffix ("mo" for
 * monthly) matches the rest of the app (CoreBoardWindowBar, StreaksPage).
 */
const CORE_STREAK_TIMEFRAMES = new Set<string>(['daily', 'weekly', 'monthly', 'yearly']);

// Module-scoped frozen empty array. Reused as a stable fallback so React
// Compiler can preserve memoization of downstream useCallback/useMemo deps;
// an inline `?? []` re-allocates on every render and trips
// `react-hooks/preserve-manual-memoization`. Typed as the mutable element
// array because consumers (legacy step helpers) require `T[]`, not
// `readonly T[]`; the runtime frozen array still throws on mutation.
const EMPTY_TASK_STEPS = Object.freeze([]) as unknown as TaskStep[];

// ─── Types ────────────────────────────────────────────────────────────────────

// `SquareDraftCell` + `FlashVariant` moved into `useBoardPlay` (B2-W3, issue
// #270). `FlashVariant` is imported below for `showFlash`'s signature.

interface FlashMessage {
  text: string;
  // The transient flash only ever holds 'bingo'-class messages (lost bingo /
  // reactivated / errors); greenlog + new bingos are intercepted in showFlash.
  variant: 'bingo';
}

export interface BoardPlaySurfaceProps {
  /** The resolved board to play. Never null/undefined — the container guards loading/not-found. */
  board: Board;
  /** Active user id, used for workspace-wide compound/achievement lookups. */
  userId: string | undefined;
  /** Chrome rendered at the very top of the container (back link on the
   *  plain page; the window bar in the pager). */
  header?: React.ReactNode;
  /**
   * When false, the Edit button is hidden even on ACTIVE boards.
   * Use in embedded contexts (e.g., the core-board pager) where in-place
   * edit would conflict with the pager's own chrome. Defaults to true.
   */
  allowEdit?: boolean;
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
export function BoardPlaySurface({ board, userId, header, allowEdit = true }: BoardPlaySurfaceProps): React.ReactElement {
  // ── Reactive data ──────────────────────────────────────────────────────
  // The read-model (live-query results + derived lookups) is built by
  // `useBoardPlayData` — extracted from this component (B2-W1, issue #270).

  const {
    boardTasks,
    taskMap,
    compoundChildrenByCompound,
    allBoardTasks,
    allBoards,
    achievementBadgesByBoardTaskId,
    sharedCounterSourceIds,
    sharedCounterHintsByTaskId,
    sortedBoardTasks,
    gridSize,
    btByPosition,
    isExpired,
    squareWindowContext,
  } = useBoardPlayData(board, userId);

  // Windowed Completion — sealed boards are a frozen, read-only historical
  // record (docs §Effects of sealed): the grid renders `done` from the stored
  // `sealedCompletedCells` snapshot (not live event queries), and every play
  // interaction (tap, context menu, +, edit entry) is disabled.
  const isSealed = board.sealedAt != null;
  const sealedCellSet = useMemo(
    () => new Set(isSealed ? (board.sealedCompletedCells ?? []) : []),
    [isSealed, board.sealedCompletedCells],
  );

  // ── UI state ───────────────────────────────────────────────────────────

  const navigate = useNavigate();
  const [flashMessage, setFlashMessage] = useState<FlashMessage | null>(null);
  // Riso bingo toast (keyed to replay the drop) + greenlog overlay.
  const [bingoToast, setBingoToast] = useState<{ key: number } | null>(null);
  const [greenlogOpen, setGreenlogOpen] = useState(false);
  // Share sheet: opens from the GREENLOG overlay's "Share my board" button.
  const [shareSheetOpen, setShareSheetOpen] = useState(false);
  const bingoTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [selectedSquareId, setSelectedSquareId] = useState<string | null>(null);
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);
  const [openedTaskInLibrary, setOpenedTaskInLibrary] = useState<string | null>(null);
  const flashTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Edit mode: replaces the stats rail with the in-place edit panel (Phase 1).
  const [editMode, setEditMode] = useState(false);
  // "Board saved" green toast shown after a successful edit-mode save.
  const [savedToast, setSavedToast] = useState(false);
  const savedToastTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Phase 2 — Shared Counters: credited toast shown after an increment/decrement
  // that ripples to OTHER boards. The `key` field forces CounterLogToast to
  // remount (resetting its timer) when consecutive logs fire quickly.
  // R3: amount-aware + Undo — shape matches `useBoardPlay`'s `CreditedToast`.
  const [creditedToast, setCreditedToast] = useState<CreditedToast | null>(null);

  // R3 — quick-action amount state for the detail modal's chip picker.
  // Seeded to the counter's current default whenever a NEW square's modal
  // opens (keyed on `selectedSquareId`); cleared when the modal closes. Not
  // reset by live-query updates so an in-progress custom-amount edit
  // survives background writes.
  const [modalQuickAmount, setModalQuickAmount] = useState<{
    boardTaskId: string;
    selected: number;
    isCustomActive: boolean;
    customOpen: boolean;
    customDraft: string;
  } | null>(null);
  // M3 — cell swap: the boardTaskId whose square the user requested a swap for.
  const [swapBoardTaskId, setSwapBoardTaskId] = useState<string | null>(null);
  // M4 — remove from board: the boardTaskId pending removal confirmation.
  const [removeBoardTaskId, setRemoveBoardTaskId] = useState<string | null>(null);
  // M4 — add to empty cell: the grid position {row, col} awaiting task selection.
  const [addCellPos, setAddCellPos] = useState<{ row: number; col: number } | null>(null);

  // R3 — seed/reset the detail-modal quick-action amount whenever a
  // DIFFERENT square's modal opens (or closes). Deliberately keyed only on
  // `selectedSquareId` — a live-query update to boardTasks/taskMap while the
  // SAME modal stays open must not clobber an in-progress custom-amount edit.
  useEffect(() => {
    if (!selectedSquareId) {
      setModalQuickAmount(null);
      return;
    }
    const bt = boardTasks.find((b) => b.id === selectedSquareId);
    const task = bt ? taskMap[bt.taskId] : undefined;
    if (!task || task.type !== TaskType.COUNTING) return;
    const sourceId = resolveSharedCounterSourceId(task, sharedCounterSourceIds);
    if (!sourceId) return; // Standalone counting square — no quick-action row.
    setModalQuickAmount({
      boardTaskId: selectedSquareId,
      selected: resolveSharedCounterDefaultAmount(taskMap[sourceId]),
      isCustomActive: false,
      customOpen: false,
      customDraft: '',
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedSquareId]);

  // Edit-mode draft state (subMode / squaresDraft / taskOverrides /
  // draftCenterType / freeCenterTapMenu / squareTapMenu / editReplaceId /
  // editTaskSheetId), the derived squareEditCount + draftByPosition, and the
  // seeding/reset effect all moved into `useBoardPlay` (B2-W3, issue #270).
  // `editMode` itself stays here — it's pure chrome (set from the JSX Edit
  // button + BoardEditPanel Cancel/Save) and is passed into the hook to drive
  // the seed/reset effect.

  // User preferences (weekStartDay is forwarded to BoardEditPanel + BoardSetupForm).
  const [prefs] = usePreferences();

  // Clean up timers on unmount.
  useEffect(() => {
    return () => {
      if (flashTimerRef.current) clearTimeout(flashTimerRef.current);
      if (bingoTimerRef.current) clearTimeout(bingoTimerRef.current);
      if (savedToastTimerRef.current) clearTimeout(savedToastTimerRef.current);
    };
  }, []);

  // ── Derived data ───────────────────────────────────────────────────────
  // achievementBadgesByBoardTaskId, sharedCounterSourceIds,
  // sharedCounterHintsByTaskId, sortedBoardTasks, gridSize, btByPosition,
  // and isExpired all come from useBoardPlayData above. The edit-mode
  // squareEditCount + draftByPosition come from useBoardPlay below.

  // ── Flash message helper ───────────────────────────────────────────────

  // Wrapped in useCallback so the function reference is stable across
  // renders. `flashTimerRef` is a stable ref so empty deps is correct.
  // The body writes the ref's `current` to track the active setTimeout
  // handle for cleanup — the `react-hooks/refs` rule
  // (eslint-plugin-react-hooks v7.1+) is conservative about ref access
  // chains; useCallback makes the function's role explicit (event-time,
  // never during render) so the analyzer doesn't flag the call sites.
  const showFlash = useCallback((text: string, variant: FlashVariant): void => {
    // Route the completion signal to the Riso surfaces:
    //  - greenlog → the full-screen overlay (persists until dismissed)
    //  - a newly-formed bingo → the drop-in toast (auto-dismiss)
    //  - everything else (lost bingo, reactivated, errors) → transient flash
    if (variant === 'greenlog') {
      setGreenlogOpen(true);
      return;
    }
    if (variant === 'bingo' && text.startsWith('Bingo!')) {
      if (bingoTimerRef.current) clearTimeout(bingoTimerRef.current);
      setBingoToast({ key: Date.now() });
      bingoTimerRef.current = setTimeout(() => setBingoToast(null), 2600);
      return;
    }
    if (flashTimerRef.current) clearTimeout(flashTimerRef.current);
    const msg = { text, variant };
    setFlashMessage(msg);
    flashTimerRef.current = setTimeout(() => {
      setFlashMessage((current) => current === msg ? null : current);
    }, FLASH_MS);
  }, []);

  // ── Handler + edit-draft layer ─────────────────────────────────────────
  // The staged edit-mode draft, the completion-orchestration handlers, and
  // the play-mode board-task write methods all live in `useBoardPlay`
  // (B2-W3, issue #270 — pure code-motion). It receives the read-model data
  // plus the transient-UI callbacks (`onFlash` = showFlash, `onCreditedToast`
  // = setCreditedToast, and setContextMenu for the error-path menu dismiss);
  // everything below is consumed by the JSX unchanged.
  const {
    squaresDraft,
    taskOverrides,
    draftCenterType,
    setDraftCenterType,
    subMode,
    setSubMode,
    squareTapMenu,
    setSquareTapMenu,
    freeCenterTapMenu,
    setFreeCenterTapMenu,
    editReplaceId,
    setEditReplaceId,
    editTaskSheetId,
    setEditTaskSheetId,
    squareEditCount,
    draftByPosition,
    arrangeSlots,
    handleEditReplace,
    handleEditTaskDone,
    handleRearrangeReorder,
    commitSquareEdits,
    handleComplete,
    handleSharedCounterIncrement,
    handleSharedCounterDecrement,
    handleCompoundChildToggle,
    swapBoardTask,
    removeBoardTask,
    addTaskToCell,
  } = useBoardPlay({
    board,
    editMode,
    boardTasks,
    taskMap,
    compoundChildrenByCompound,
    allBoardTasks,
    gridSize,
    // Sealing replaced the expiry lock (docs §Lifecycle): play handlers are
    // locked only on sealed boards; an expired-but-unsealed board stays live.
    playLocked: isSealed,
    squareWindowContext,
    onFlash: showFlash,
    onCreditedToast: setCreditedToast,
    setContextMenu,
  });

  // ── Passive completion (Shared Counters P3) ─────────────────────────────
  // Detects shared-counter squares that filled in from a log made elsewhere
  // (Counter Detail / another board) and drives the gold arrival banner + the
  // per-cell pulse. Latched to fire once per board-open; a local tap here never
  // masquerades as an arrival. Edit mode has no shared-counter play, so the
  // banner is suppressed while editing.
  const { arrival, arrivedTaskIds, dismiss: dismissArrival } = useCounterArrivals({
    boardId: board.id,
    boardTasks,
    taskMap,
    sharedCounterSourceIds,
  });

  // The banner's tap target: the single distinct arrived counter's Detail page,
  // or the Counters Hub when squares arrived from more than one counter (the
  // doc's "N squares … your counters" copy names no single counter). Its copy
  // strings (single-square variant) resolve from the one arrived square's task.
  const arrivalNav = useCallback(() => {
    if (!arrival) return;
    dismissArrival();
    if (arrival.arrivedCounters.length === 1) {
      navigate(`/profile/counters/${arrival.arrivedCounters[0].counterId}`);
    } else {
      navigate('/profile/counters');
    }
  }, [arrival, dismissArrival, navigate]);

  // Single-square copy needs the arrived square's task name + its counter name.
  // Resolve the display label (title, or the auto-generated "Action N unit" for
  // a titleless counting task) so a blank-titled counter still reads as "single".
  const arrivalSingle = (() => {
    if (!arrival || arrival.totalArrivedSquares !== 1) return null;
    const taskId = [...arrival.arrivedTaskIds][0];
    const t = taskId ? taskMap[taskId] : undefined;
    const taskName = t
      ? t.title && t.title.trim()
        ? t.title
        : generateCounterTaskTitle(t.action ?? '', t.maxCount, t.unit ?? '')
      : '';
    const counterName = arrival.arrivedCounters[0]?.counterName ?? '';
    return { taskName, counterName };
  })();

  // ── Render ─────────────────────────────────────────────────────────────

  // Compute streak once so both RisoGreenlog and ShareBoardSheet use the same value.
  const greenlogStreak = computeStreak(
    board.timeframe,
    AchievementTrigger.GREENLOG,
    allBoards,
    prefs.weekStartDay,
    new Date(),
  );

  // Format as compact label for the share poster (e.g. "3d", "2w", "5mo").
  // Only core boards (daily/weekly/monthly/yearly) have streaks; CUSTOM/INDEFINITE
  // fall through to undefined so the poster's STREAK card is hidden.
  const shareStreakLabel: string | undefined =
    greenlogStreak > 0 && CORE_STREAK_TIMEFRAMES.has(board.timeframe)
      ? compactStreakLabel(greenlogStreak, board.timeframe)
      : undefined;

  return (
    <div className={play.play}>
      {/* Greenlog overlay (page green, squares stay red) */}
      {greenlogOpen && (
        <RisoGreenlog
          boardName={board.name}
          boardSize={board.boardSize}
          bingos={board.linesCompleted}
          streak={greenlogStreak}
          celebrationIntensity={prefs.celebrationIntensity}
          onShare={() => setShareSheetOpen(true)}
          onNewBoard={() => navigate('/create')}
          onClose={() => setGreenlogOpen(false)}
        />
      )}

      {/* Share poster sheet — opens from the GREENLOG "Share my board" button */}
      {shareSheetOpen && (
        <ShareBoardSheet
          boardName={board.name}
          completedTasks={board.completedTasks}
          totalTasks={board.totalTasks}
          linesCompleted={board.linesCompleted}
          streak={shareStreakLabel}
          onDismiss={() => setShareSheetOpen(false)}
        />
      )}
      {/* Bingo toast */}
      {bingoToast && <RisoBingoToast key={bingoToast.key} count={board.linesCompleted} />}

      {/* Arrival banner — passive-completion (Shared Counters P3). Suppressed in
          edit mode (no shared-counter play while editing). */}
      {arrival && !editMode && (
        <RisoArrivalBanner
          key={arrival.key}
          squareCount={arrival.totalArrivedSquares}
          taskName={arrivalSingle?.taskName}
          counterName={arrivalSingle?.counterName}
          onOpen={arrivalNav}
          onDismiss={dismissArrival}
        />
      )}

      {/* Credited toast — shared-counter ripple feedback (R3: amount-aware + Undo) */}
      {creditedToast && (
        <CounterLogToast
          key={creditedToast.key}
          amount={creditedToast.amount}
          unit=""
          verb={creditedToast.verb}
          counterName={creditedToast.counterName}
          boardNames={creditedToast.boardNames}
          onUndo={() => {
            const sourceTaskId = creditedToast.sourceTaskId;
            setCreditedToast(null);
            void undoLastCounterLog(sourceTaskId);
          }}
          onDone={() => setCreditedToast(null)}
        />
      )}

      {/* Transient flash — lost bingo / reactivated / errors (bingo + greenlog
          route to the toast/overlay above). */}
      {flashMessage && (
        <div className={`${styles.flashMessage} ${styles.flashBingo}`} role="status" aria-live="polite">
          {flashMessage.text}
        </div>
      )}

      {/* Left rail — normal stats rail OR the in-place edit panel */}
      {editMode ? (
        /* Edit mode: replace the stats rail with the metadata edit panel.
           BoardEditPanel renders inside the same sticky play.rail aside so
           the two-column .play layout is preserved. */
        <aside className={play.rail}>
          <BoardEditPanel
            board={board}
            weekStartDay={prefs.weekStartDay}
            subMode={subMode}
            onSubModeChange={(mode) => {
              // Clear editTasks overlays when switching sub-modes so a
              // tap-menu or replace sheet open in editTasks doesn't
              // bleed into the rearrange view.
              setSubMode(mode);
              setSquareTapMenu(null);
              setFreeCenterTapMenu(null); // Phase 2b
              setEditReplaceId(null);
              setEditTaskSheetId(null);
            }}
            squareEditCount={squareEditCount}
            onExtraCommit={commitSquareEdits}
            onCancel={() => setEditMode(false)}
            onSaved={() => {
              setEditMode(false);
              setSavedToast(true);
              if (savedToastTimerRef.current) clearTimeout(savedToastTimerRef.current);
              savedToastTimerRef.current = setTimeout(() => setSavedToast(false), 2400);
            }}
            onArchived={() => navigate('/boards')}
            centerType={draftCenterType}
            onCenterTypeChange={setDraftCenterType}
          />
        </aside>
      ) : (
        /* Normal play rail: header slot + title + stats + hint */
        <aside className={play.rail}>
          <div className={play.railTop}>
            {header}
            {/* Edit entry: ACTIVE boards only, and only when the container allows
                editing (allowEdit=false in the core-board pager). Sealed boards
                are frozen — never editable (docs §Effects of sealed: not editable). */}
            {board.status === BoardStatus.ACTIVE && allowEdit && !isSealed && (
              <button
                type="button"
                className={`${play.back} ${play.iconBtn}`}
                onClick={() => setEditMode(true)}
                aria-label="Edit board"
                title="Edit board"
              >
                <RisoIcon name="dots" size={16} />
              </button>
            )}
          </div>
          <div>
            <div className={play.kicker}>{board.timeframe.toUpperCase()} BOARD</div>
            <h2 className={play.title}>{board.name}</h2>
            <div style={{ marginTop: 10, display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {isSealed ? (
                <span className={styles.sealedBadge}>Sealed</span>
              ) : (
                <BoardStatusBadge status={board.status} />
              )}
              {board.spawnedFromTemplateId != null && <RecurringBadge />}
            </div>
          </div>

          {isExpired && !isSealed && (
            <div className={styles.expiredBanner}>
              Board expired on {board.endDate ? formatDisplayDate(board.endDate) : 'unknown date'}
            </div>
          )}

          <div className={play.statStack}>
            <div className={play.stat}>
              <div className={play.statK}>Squares</div>
              <div className={play.statV}>
                {board.completedTasks}
                <small>/{board.totalTasks}</small>
              </div>
            </div>
            <div className={play.stat}>
              <div className={play.statK}>Left</div>
              <div className={play.statV} style={{ fontSize: '18px' }}>
                {getExpiryLabel(board) || '—'}
              </div>
            </div>
            <div className={`${play.stat} ${play.gold}`}>
              <div className={play.statK}>Bingos</div>
              <div className={play.statV}>
                <span className={play.starS} aria-hidden="true" />
                {board.linesCompleted}
              </div>
            </div>
          </div>

          <div className={play.hint}>
            {board.completedTasks === 0 ? (
              <>
                Resting paper. <b>Complete a square</b> to slap ink on it — fill a line for a bingo.
              </>
            ) : board.linesCompleted > 0 ? (
              <>
                Nice work — keep filling. <b>Clear the board</b> for a GREENLOG.
              </>
            ) : (
              <>
                Keep going — line up a row, column, or diagonal for a <b>bingo.</b>
              </>
            )}
          </div>
        </aside>
      )}

      {/* Board column */}
      <div className={play.boardWrap}>
      {/* Interactive grid */}
      {sortedBoardTasks.length === 0 ? (
        <p className={styles.emptyState}>Loading board tasks…</p>
      ) : editMode && subMode === 'rearrange' ? (
        /* Phase 3 — Rearrange sub-mode: full drag-to-insert + tap-to-swap grid.
           ArrangeGrid owns all pointer events; BoardPlaySurface owns the staging. */
        <ArrangeGrid
          slots={arrangeSlots}
          gridSize={gridSize}
          rearrange={true}
          onReorder={handleRearrangeReorder}
        />
      ) : (
        <div
          className={styles.playGrid}
          style={{ gridTemplateColumns: `repeat(${gridSize}, 90px)` }}
        >
          {(() => {
            const cells: React.ReactElement[] = [];
            // Gold-ring the cells in completed bingo lines.
            const highlightedSquares = getHighlightedSquares(board.completedLineIds ?? [], gridSize);

            for (let row = 0; row < gridSize; row++) {
              for (let col = 0; col < gridSize; col++) {
                const posKey = `${row}-${col}`;
                const isCenter =
                  gridSize % 2 === 1 &&
                  row === Math.floor(gridSize / 2) &&
                  col === Math.floor(gridSize / 2);

                // Phase 2b: isPinnedCenter = positional center AND type is not NONE.
                // FREE / CUSTOM_FREE / CHOSEN centers are pinned (not editable/rearrangeable).
                // NONE center is a fully normal cell — tappable, placeable, rearrangeable.
                const effectiveCenterType = editMode
                  ? draftCenterType
                  : (board.centerSquareType as CenterSquareType);
                const isPinnedCenter =
                  isCenter && effectiveCenterType !== CenterSquareType.NONE;

                // ── Resolve the cell source ──────────────────────────────
                // In edit mode, read from the squares draft (staged taskIds).
                // In play mode, read from the live boardTasks index.
                const draftCell = editMode ? draftByPosition[posKey] : undefined;
                const bt = editMode ? undefined : btByPosition[posKey];

                // Determine the boardTaskId and resolved taskId for this position.
                const boardTaskId = editMode ? draftCell?.boardTaskId : bt?.id;
                const resolvedTaskId = editMode ? draftCell?.taskId : bt?.taskId;

                // ── Empty / center cells ─────────────────────────────────
                if (!boardTaskId) {
                  // Resolve the center type for display (draft in edit mode, live in play mode).
                  const centerTypeForDisplay = editMode
                    ? draftCenterType
                    : (board.centerSquareType as CenterSquareType);
                  const isFreeCenter =
                    isCenter &&
                    (centerTypeForDisplay === CenterSquareType.FREE ||
                      centerTypeForDisplay === CenterSquareType.CUSTOM_FREE);

                  if (isFreeCenter && !editMode) {
                    // Play mode: static FREE label.
                    cells.push(
                      <div key={`center-${row}-${col}`} className={styles.freeSquare}>
                        FREE
                      </div>
                    );
                  } else if (isFreeCenter && editMode && subMode === 'editTasks') {
                    // Phase 2b — Edit mode, editTasks sub-mode: FREE center is
                    // tappable so the user can toggle it to a task square.
                    cells.push(
                      <button
                        key={`center-${row}-${col}`}
                        type="button"
                        className={`${styles.freeSquare} ${styles.editableFreeSquare}`}
                        aria-label="Free space — tap to convert to a task square"
                        onClick={(e) => {
                          setFreeCenterTapMenu({ x: e.clientX, y: e.clientY });
                        }}
                      >
                        FREE
                      </button>
                    );
                  } else if (isFreeCenter && editMode) {
                    // Rearrange sub-mode: FREE center is not tappable (pinned display).
                    cells.push(
                      <div key={`center-${row}-${col}`} className={styles.freeSquare}>
                        FREE
                      </div>
                    );
                  } else {
                    // Empty cell (non-center, or NONE center with no task in edit mode,
                    // or NONE center with no task in play mode — all treated as empty).
                    // M4 — show `+` affordance on ACTIVE non-expired boards in play mode.
                    // Phase 2b: NONE center is eligible (not blocked by isPinnedCenter).
                    const addEligible =
                      !editMode &&
                      !isPinnedCenter &&
                      board.status === BoardStatus.ACTIVE &&
                      !isSealed;
                    cells.push(
                      <div
                        key={`empty-${row}-${col}`}
                        className={styles.emptySquare}
                      >
                        {addEligible && (
                          <button
                            type="button"
                            className={styles.addTaskButton}
                            aria-label="Add task to this cell"
                            onClick={() => setAddCellPos({ row, col })}
                          >
                            +
                          </button>
                        )}
                      </div>
                    );
                  }
                  continue;
                }

                // ── Resolve the base task from taskMap ───────────────────
                const baseTask: Task | undefined = resolvedTaskId ? taskMap[resolvedTaskId] : undefined;
                if (!baseTask) {
                  cells.push(
                    <div key={`missing-${boardTaskId}`} className={styles.emptySquare}>?</div>
                  );
                  continue;
                }

                // In edit mode, apply any staged task-field overrides for display.
                // In play mode, use the base task directly (no overrides).
                const task: Task = (editMode && resolvedTaskId && taskOverrides.has(resolvedTaskId))
                  ? { ...baseTask, ...taskOverrides.get(resolvedTaskId) as Partial<Task> }
                  : baseTask;

                const taskChildren = compoundChildrenByCompound[task.id] ?? [];
                const squareData = taskToSquareData(
                  task, EMPTY_TASK_STEPS, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
                );
                const squareState = taskToSquareState(
                  task, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
                );
                // Windowed Completion — on a SEALED board, `done` reads the
                // frozen `sealedCompletedCells` snapshot (docs §Effects of
                // sealed), never live event queries (which could bleed a
                // post-seal log of the same task from another live board).
                const cellIndex = row * gridSize + col;
                const taskIsCompleted = isSealed
                  ? sealedCellSet.has(cellIndex)
                  : squareState.isCompleted;
                // Use squareState.currentCount (baseline-adjusted for linked
                // counters). For standalone counters this equals task.currentCount.
                // On a sealed board only completion was snapshotted (not partial
                // progress), so a frozen counting square reads max/max when green
                // and 0/max otherwise — an honest read of what was frozen.
                const taskCurrentCount = isSealed
                  ? (taskIsCompleted ? (task.maxCount ?? 0) : 0)
                  : squareState.currentCount;

                // Resolve the display label:
                // - If the task has a title, use it.
                // - For COUNTING tasks without a title, generate from action+maxCount+unit.
                const displayLabel = task.title && task.title.trim()
                  ? task.title
                  : (task.type === TaskType.COUNTING
                      ? generateCounterTaskTitle(task.action ?? '', task.maxCount, task.unit ?? '')
                      : '');

                // Phase 2 — Shared Counters: mark the cell as shared when
                // it is a source OR a linked derived counter, so the
                // two-dot ↔ marker appears on the grid while not done.
                const isSharedCountingTask =
                  squareData.type === 'counting' &&
                  !taskIsCompleted &&
                  (task.sharedCounterId != null || sharedCounterSourceIds.has(task.id));

                const cellModel: BoardCellModel = {
                  key: boardTaskId,
                  label: displayLabel,
                  type:
                    squareData.type === 'counting'
                      ? 'counting'
                      : squareData.type === 'compound' || squareData.type === 'progress'
                        ? 'compound'
                        : 'normal',
                  done: taskIsCompleted,
                  count:
                    squareData.type === 'counting'
                      ? { cur: taskCurrentCount, max: task.maxCount ?? 0 }
                      : undefined,
                  isFree: false,
                  isLine: highlightedSquares.has(row * gridSize + col),
                  isShared: isSharedCountingTask || undefined,
                  // Phase 3 — pulse squares that just filled in from an
                  // elsewhere log (play mode only; suppressed while editing).
                  isArrived: (!editMode && resolvedTaskId != null && arrivedTaskIds.has(resolvedTaskId)) || undefined,
                };

                // ── Click handler (play mode) ────────────────────────────
                // Edit mode taps are handled by a wrapper div below (we need
                // mouse coordinates which RisoBoardCell's onClick: () => void
                // does not expose).
                // Sealing REPLACES the old expiry-based interaction lock
                // (docs §Lifecycle: an expired-but-unsealed board is "still
                // fully live" — the closing-out banner's Log action opens it
                // to log late activity; the backstop bounds the overtime).
                const handlePlayClick = (!editMode && !isSealed)
                  ? () => {
                      if (squareData.type === 'progress' || squareData.type === 'compound') {
                        setSelectedSquareId(boardTaskId);
                      } else if (squareData.type === 'counting') {
                        // Phase 3 — Shared Counters routing:
                        //  (a) Linked derived counter (task.sharedCounterId != null):
                        //      tap increments the source task, propagates to all siblings.
                        //  (b) Source counter (task.id in sharedCounterSourceIds):
                        //      tap increments source + propagates to all linked tasks.
                        //  (c) Standalone counter (no shared link at all):
                        //      falls through to the legacy handleComplete path.
                        // All shared-counter paths forbid the old high-end clamp (overshoot allowed).
                        // R3 — a plain tap on a shared counting square logs the
                        // counter's default amount (was hardcoded 1); the
                        // one-tap path never persists a new default.
                        const sourceId = resolveSharedCounterSourceId(task, sharedCounterSourceIds);
                        if (sourceId) {
                          const amount = resolveSharedCounterDefaultAmount(taskMap[sourceId]);
                          void handleSharedCounterIncrement(sourceId, amount, false);
                        } else {
                          // Standalone (unlinked) counting task — no propagation needed.
                          const next = taskCurrentCount + 1;
                          void handleComplete(boardTaskId, { currentCount: next });
                        }
                      } else {
                        void handleComplete(boardTaskId, {
                          isCompleted: !taskIsCompleted,
                        });
                      }
                    }
                  : undefined;

                // ── Edit-mode cell wrapper ───────────────────────────────
                // In editTasks sub-mode, non-pinned cells are wrapped in a
                // button that captures the click position for the tap menu.
                // RisoBoardCell itself gets onClick=undefined (display-only);
                // the wrapper provides the pointer cursor and accessibility role.
                //
                // Phase 2b: isPinnedCenter replaces !isCenter — a NONE center
                // (isPinnedCenter=false) IS a valid tap target in editTasks mode.
                const isEditTapTarget =
                  editMode && subMode === 'editTasks' && !isPinnedCenter;
                const capturedBoardTaskId = boardTaskId;
                const capturedTaskId = resolvedTaskId ?? task.id;
                // Phase 2b: mark if this cell is the unpinned center (NONE type)
                // so SquareTapMenu can show the "Make it a free space" toggle.
                const isCenterTask = isCenter && draftCenterType === CenterSquareType.NONE;

                const cellNode = (
                  <RisoBoardCell
                    cell={cellModel}
                    badge={
                      achievementBadgesByBoardTaskId[boardTaskId] ? (
                        <span className={play.achvBadge} title="Achievement">
                          A
                        </span>
                      ) : undefined
                    }
                    onClick={editMode ? undefined : handlePlayClick}
                    onContextMenu={editMode ? undefined : (e) => {
                      if (isSealed) return;
                      e.preventDefault();
                      setContextMenu({ squareId: boardTaskId, x: e.clientX, y: e.clientY });
                    }}
                  />
                );

                cells.push(
                  isEditTapTarget ? (
                    <button
                      key={boardTaskId}
                      type="button"
                      className={styles.editCellBtn}
                      aria-label={`Edit square: ${displayLabel}`}
                      onClick={(e) => {
                        setSquareTapMenu({
                          boardTaskId: capturedBoardTaskId,
                          taskId: capturedTaskId,
                          x: e.clientX,
                          y: e.clientY,
                          isCenterTask, // Phase 2b
                        });
                      }}
                    >
                      {cellNode}
                    </button>
                  ) : cellNode,
                );
              }
            }

            return cells;
          })()}
        </div>
      )}

      </div>

      {/* ── Phase 2 — Edit-mode overlays ────────────────────────────────────── */}

      {/* Square tap menu: shown when tapping a non-center cell in editTasks mode. */}
      {editMode && squareTapMenu && (() => {
        const menuTaskId = squareTapMenu.taskId;
        // Resolve task title for display — apply any staged override.
        const menuBaseTask = taskMap[menuTaskId];
        const menuOverride = taskOverrides.get(menuTaskId);
        const menuTask = menuBaseTask
          ? (menuOverride ? { ...menuBaseTask, ...menuOverride as Partial<Task> } : menuBaseTask)
          : undefined;
        // Mirror the square's displayLabel: counting tasks with a blank title
        // show their auto-generated "Action N unit" name, not "(untitled)".
        const menuTitle =
          menuTask && menuTask.title && menuTask.title.trim()
            ? menuTask.title
            : menuTask?.type === TaskType.COUNTING
              ? generateCounterTaskTitle(
                  menuTask.action ?? '',
                  menuTask.maxCount ?? 0,
                  menuTask.unit ?? '',
                )
              : '(untitled)';
        return (
          <SquareTapMenu
            taskTitle={menuTitle}
            x={squareTapMenu.x}
            y={squareTapMenu.y}
            onReplace={() => {
              setEditReplaceId(squareTapMenu.boardTaskId);
            }}
            onEdit={() => {
              setEditTaskSheetId(squareTapMenu.taskId);
            }}
            // Phase 2b: NONE center task shows "Make it a free space" toggle.
            onMakeFree={squareTapMenu.isCenterTask ? () => {
              setDraftCenterType(CenterSquareType.FREE);
            } : undefined}
            onClose={() => setSquareTapMenu(null)}
          />
        );
      })()}

      {/* Phase 2b — Center toggle menu: shown when tapping a FREE/CUSTOM_FREE
          center in editTasks mode. No boardTaskId (free centers have no task). */}
      {editMode && freeCenterTapMenu && (
        <SquareTapMenu
          taskTitle="Free space"
          x={freeCenterTapMenu.x}
          y={freeCenterTapMenu.y}
          onMakeTask={() => {
            setDraftCenterType(CenterSquareType.NONE);
          }}
          onClose={() => setFreeCenterTapMenu(null)}
        />
      )}

      {/* Edit-mode Replace: opens CellSwapModal to pick a new task.
          On confirm, stages the replacement in the draft (no DB write). */}
      {editMode && editReplaceId && (() => {
        const replaceDraftCell = squaresDraft.find((c) => c.boardTaskId === editReplaceId);
        if (!replaceDraftCell) return null;
        return (
          <CellSwapModal
            mode="swap"
            currentTaskId={replaceDraftCell.taskId}
            candidateTasks={Object.values(taskMap)}
            onClose={() => setEditReplaceId(null)}
            onConfirm={(newTaskId) => {
              handleEditReplace(editReplaceId, newTaskId);
              setEditReplaceId(null);
            }}
          />
        );
      })()}

      {/* Edit-mode Task editor: opens BoardEditTaskSheet to stage field changes.
          On Done, stages the patch in taskOverrides (no DB write). */}
      {editMode && editTaskSheetId && (() => {
        const sheetBaseTask = taskMap[editTaskSheetId];
        if (!sheetBaseTask) return null;
        // Pre-merge any already-staged overrides so re-opening shows prior edits.
        const sheetOverride = taskOverrides.get(editTaskSheetId);
        const sheetTask: Task = sheetOverride
          ? { ...sheetBaseTask, ...sheetOverride as Partial<Task> }
          : sheetBaseTask;
        return (
          <BoardEditTaskSheet
            task={sheetTask}
            onDone={(taskId, patch) => {
              handleEditTaskDone(taskId, patch);
              setEditTaskSheetId(null);
            }}
            onCancel={() => setEditTaskSheetId(null)}
          />
        );
      })()}

      {/* Detail Modal, context menu, swap modal, remove/add modals — all hidden
          in edit mode (the grid is display-only; no tap interactions allowed). */}
      {!editMode && selectedSquareId && (() => {
        const bt = boardTasks.find((b) => b.id === selectedSquareId);
        if (!bt) return null;
        const task = taskMap[bt.taskId];
        if (!task) return null;
        const taskChildren = compoundChildrenByCompound[task.id] ?? [];
        const squareData = taskToSquareData(
          task, EMPTY_TASK_STEPS, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
        );
        const squareState = taskToSquareState(
          task, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
        );
        // Use squareState.currentCount (baseline-adjusted for linked counters)
        // rather than the raw task.currentCount accumulator. For standalone
        // counters the two values are identical; for linked derived counters
        // taskToSquareState has already applied deriveDisplayedCount.
        const modalCurrentCount = squareState.currentCount;
        // Linked derived counters are read-only: their value is driven by the
        // source task. Decrement and reset must be disabled for them.
        const isLinkedCounter = squareData.sharedCounterId != null;

        // Phase 2 — resolve the shared-counter hint for this task.
        const modalSharedHint = sharedCounterHintsByTaskId.get(task.id);

        // R3 — quick-action amount picker (shared counting squares only).
        const modalSourceId = resolveSharedCounterSourceId(task, sharedCounterSourceIds);
        const activeQuickAmount =
          modalQuickAmount && modalQuickAmount.boardTaskId === bt.id ? modalQuickAmount : null;
        const modalDefaultAmount = resolveSharedCounterDefaultAmount(
          modalSourceId ? taskMap[modalSourceId] : undefined,
        );
        const quickSelected = activeQuickAmount?.selected ?? modalDefaultAmount;
        const quickAmount =
          squareData.type === 'counting' && modalSourceId
            ? {
                options: buildBoardQuickAmountOptions(modalDefaultAmount),
                selected: quickSelected,
                isCustomActive: activeQuickAmount?.isCustomActive ?? false,
                customOpen: activeQuickAmount?.customOpen ?? false,
                customDraft: activeQuickAmount?.customDraft ?? '',
                unit: task.unit ?? '',
                busy: isSealed,
                onSelectChip: (value: number) =>
                  setModalQuickAmount({
                    boardTaskId: bt.id,
                    selected: value,
                    isCustomActive: false,
                    customOpen: false,
                    customDraft: '',
                  }),
                onOpenCustom: () =>
                  setModalQuickAmount((prev) => ({
                    boardTaskId: bt.id,
                    selected: prev?.selected ?? modalDefaultAmount,
                    isCustomActive: prev?.isCustomActive ?? false,
                    customOpen: true,
                    customDraft: prev?.isCustomActive ? String(prev.selected) : '',
                  })),
                onCustomDraftChange: (raw: string) =>
                  setModalQuickAmount((prev) => (prev ? { ...prev, customDraft: raw } : prev)),
                onConfirmCustom: () => {
                  const parsed = parseCustomLogAmount(activeQuickAmount?.customDraft ?? '');
                  if (parsed == null) return;
                  setModalQuickAmount({
                    boardTaskId: bt.id,
                    selected: parsed,
                    isCustomActive: true,
                    customOpen: false,
                    customDraft: '',
                  });
                },
                onAdd: () => {
                  if (isSealed) return;
                  // R3 — an explicit custom "#" amount persists as the new
                  // default; the 1/{default} chips are a quick nudge, not a
                  // preference change (Global Constraints asymmetry vs R2).
                  void handleSharedCounterIncrement(
                    modalSourceId,
                    quickSelected,
                    activeQuickAmount?.isCustomActive ?? false,
                  );
                },
                onRemove: () => {
                  if (isSealed || isLinkedCounter) return;
                  void handleSharedCounterDecrement(
                    modalSourceId,
                    quickSelected,
                    activeQuickAmount?.isCustomActive ?? false,
                  );
                },
                removeDisabled: isLinkedCounter || modalCurrentCount <= 0,
                removeTitle: isLinkedCounter ? 'Linked counters cannot be decremented directly' : undefined,
              }
            : undefined;

        return (
          <DetailModal
            sq={squareData}
            state={squareState}
            onClose={() => setSelectedSquareId(null)}
            onToggleComplete={() => {
              if (isSealed) return;
              // `handleComplete` now comes from `useBoardPlay`; the ref-access
              // chain that previously tripped `react-hooks/refs` is no longer
              // visible to the analyzer (the handler is an opaque hook return),
              // so the per-site disable directives here were removed (B2-W3).
              void handleComplete(bt.id, { isCompleted: !squareState.isCompleted });
            }}
            onIncrementCount={() => {
              // Standalone (non-shared) counting squares only — shared squares
              // route through `quickAmount.onAdd` above.
              if (isSealed) return;
              void handleComplete(bt.id, { currentCount: modalCurrentCount + 1 });
            }}
            onDecrementCount={() => {
              // Standalone (non-shared) counting squares only — shared squares
              // route through `quickAmount.onRemove` above.
              if (isSealed) return;
              if (modalCurrentCount > 0) void handleComplete(bt.id, { currentCount: modalCurrentCount - 1 });
            }}
            onToggleStep={(stepId: string) => {
              if (isSealed) return;
              // Per-board step completion is not tracked under the unified model.
              // Progress steps link to their own Task records; toggle them directly.
              void handleCompoundChildToggle(stepId);
            }}
            onCompoundChildToggle={
              squareData.type === 'compound' ? handleCompoundChildToggle : undefined
            }
            onOpenInLibrary={(taskId) => setOpenedTaskInLibrary(taskId)}
            sharedHint={modalSharedHint}
            quickAmount={quickAmount}
          />
        );
      })()}

      {/* Task library sheet — "Open in library" from context menu or compound child rows */}
      {!editMode && (
        <TaskDetailSheet
          taskId={openedTaskInLibrary}
          onClose={() => setOpenedTaskInLibrary(null)}
          onOpenTask={(id) => setOpenedTaskInLibrary(id)}
        />
      )}

      {/* Floating Context Menu */}
      {!editMode && contextMenu && (() => {
        const bt = boardTasks.find((b) => b.id === contextMenu.squareId);
        if (!bt) return null;
        const task = taskMap[bt.taskId];
        if (!task) return null;
        const taskChildren = compoundChildrenByCompound[task.id] ?? [];
        const squareData = taskToSquareData(
          task, EMPTY_TASK_STEPS, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
        );
        const squareState = taskToSquareState(
          task, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
        );
        // Use squareState.currentCount (baseline-adjusted for linked counters).
        const menuCurrentCount = squareState.currentCount;
        // Linked derived counters are read-only — decrement/reset must be gated.
        const isLinkedCounter = squareData.sharedCounterId != null;

        // M3 — Swap is available on ACTIVE non-sealed squares that are not a
        // pinned center (sealed replaces the old expiry gate; the context menu
        // is unreachable on sealed boards anyway). Phase 2b: NONE center
        // (bt.isCenter may be true in DB for wizard-placed boards) is swappable
        // — only FREE/CUSTOM_FREE/CHOSEN centers are pinned.
        const swapEligible =
          board.status === BoardStatus.ACTIVE &&
          !isSealed &&
          !(bt.isCenter && board.centerSquareType !== CenterSquareType.NONE);

        // Phase 2 — resolve the shared-counter hint for this task.
        const menuSharedHint = sharedCounterHintsByTaskId.get(task.id);

        // R3 — quick-action amount options (shared counting squares only).
        // The "# Custom amount…" item opens the detail modal (which owns
        // the full picker) rather than an inline input — see the prop's
        // docstring on `FloatingContextMenu` for why.
        const menuSourceId = resolveSharedCounterSourceId(task, sharedCounterSourceIds);
        const sharedAmountActions =
          squareData.type === 'counting' && menuSourceId
            ? {
                unit: task.unit ?? '',
                defaultAmount: resolveSharedCounterDefaultAmount(taskMap[menuSourceId]),
                onAdd: (amount: number) => void handleSharedCounterIncrement(menuSourceId, amount, false),
                onOpenCustom: () => setSelectedSquareId(bt.id),
              }
            : undefined;

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
              // Standalone (non-shared) counting squares only — shared
              // squares route through `sharedAmountActions.onAdd` above.
              void handleComplete(bt.id, { currentCount: menuCurrentCount + 1 });
              setContextMenu(null);
            }}
            onDecrementCount={() => {
              // Linked derived counters are read-only — no decrement.
              if (isLinkedCounter) { setContextMenu(null); return; }
              // Phase 2 — Source shared counters route through decrementSharedCounter.
              if (sharedCounterSourceIds.has(task.id)) {
                void handleSharedCounterDecrement(task.id);
              } else if (menuCurrentCount > 0) {
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
            onRemoveFromBoard={swapEligible ? () => {
              setRemoveBoardTaskId(bt.id);
              setContextMenu(null);
            } : undefined}
            sharedHint={menuSharedHint}
            sharedAmountActions={sharedAmountActions}
          />
        );
      })()}

      {/* M3 — Cell Swap Modal */}
      {!editMode && swapBoardTaskId && (() => {
        const bt = boardTasks.find((b) => b.id === swapBoardTaskId);
        if (!bt) return null;
        return (
          <CellSwapModal
            mode="swap"
            currentTaskId={bt.taskId}
            candidateTasks={Object.values(taskMap)}
            onClose={() => setSwapBoardTaskId(null)}
            onConfirm={async (newTaskId) => {
              setSwapBoardTaskId(null);
              // The DB write + error flash live in `useBoardPlay.swapBoardTask`
              // (B2-W3); the modal-dismiss stays here (routing state).
              await swapBoardTask(swapBoardTaskId, newTaskId);
            }}
          />
        );
      })()}

      {/* M4 — Remove from board confirmation */}
      {!editMode && removeBoardTaskId && (() => {
        const bt = boardTasks.find((b) => b.id === removeBoardTaskId);
        const task = bt ? taskMap[bt.taskId] : undefined;
        return (
          <div
            className={styles.removeConfirmBackdrop}
            onClick={() => setRemoveBoardTaskId(null)}
            role="presentation"
          >
            <div
              className={styles.removeConfirmDialog}
              onClick={(e) => e.stopPropagation()}
              role="dialog"
              aria-modal="true"
              aria-labelledby="remove-confirm-title"
              aria-describedby="remove-confirm-body"
            >
              <h3 id="remove-confirm-title" className={styles.removeConfirmTitle}>
                Remove from board?
              </h3>
              <p id="remove-confirm-body" className={styles.removeConfirmBody}>
                <strong>{task?.title ?? 'This task'}</strong> will be removed from this board.
                The task stays in your library and on any other boards where it appears.
              </p>
              <div className={styles.removeConfirmButtons}>
                <button
                  type="button"
                  className={styles.removeConfirmCancel}
                  onClick={() => setRemoveBoardTaskId(null)}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className={styles.removeConfirmDanger}
                  onClick={async () => {
                    const targetId = removeBoardTaskId;
                    setRemoveBoardTaskId(null);
                    // DB write + error flash live in `useBoardPlay.removeBoardTask`.
                    await removeBoardTask(targetId);
                  }}
                >
                  Remove
                </button>
              </div>
            </div>
          </div>
        );
      })()}

      {/* M4 — Add task to empty cell modal */}
      {!editMode && addCellPos && (
        <CellSwapModal
          mode="add"
          candidateTasks={Object.values(taskMap)}
          onClose={() => setAddCellPos(null)}
          onConfirm={async (taskId) => {
            const pos = addCellPos;
            setAddCellPos(null);
            // DB write + error flash live in `useBoardPlay.addTaskToCell`.
            await addTaskToCell(taskId, pos.row, pos.col);
          }}
        />
      )}

      {/* "Board saved" toast — displayed after a successful edit-mode save (~2.4s). */}
      {savedToast && (
        <div className={play.savedToast} role="status" aria-live="polite">
          <div className={play.savedToastIco} aria-hidden="true">✓</div>
          <div className={play.savedToastH}>Board saved</div>
        </div>
      )}
    </div>
  );
}
