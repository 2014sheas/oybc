import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AchievementTrigger,
  buildCounterFamilyMap,
  isBoardEnded,
  isCoreBoard,
  type Board,
} from '@oybc/shared';
import {
  useBoardPlayData,
  useBoardPlay,
  useCounterArrivals,
} from '../hooks';
import { placedTaskFor } from '../db/adapters';
import { SquareMenuHost } from './boardPlay/squareMenu/SquareMenuHost';
import type { ContextMenuState } from './interactiveTaskSquareUtils';
import { SquareSheetHost } from './boardPlay/squareSheet/SquareSheetHost';
import { useSquareToasts } from './boardPlay/squareSheet/useSquareToasts';
import { recurringBadgeState } from './boards/recurringBadgeState';
import { RecurringBadge } from './RecurringBadge';
import { TaskDetailSheet } from './TaskDetailSheet';
import { BoardEditPanel } from './boardEdit/BoardEditPanel';
import { BoardEditColumn } from './boardEdit/BoardEditColumn';
import type { EditSlot } from '../hooks/useSquaresEditDraft';
import { SquareTapMenu } from './boardEdit/SquareTapMenu';
import { SquarePickerSheet, type SquarePick } from './boardEdit/SquarePickerSheet';
import { isSquarePickerCandidate } from './boardEdit/squarePickerCandidates';
import { BoardEditTaskSheet } from './boardEdit/BoardEditTaskSheet';
import { BoardEditButton } from './boardActions/BoardEditButton';
import { canEditSquares } from './boardActions/boardMenu';
import { usePreferences } from '../hooks/usePreferences';
import { useNavigate } from 'react-router-dom';
import {
  boardDisplayName, compactStreakLabel,
} from '@oybc/shared';
import { gatedStreak } from '../utils/gatedStreak';
import { RisoIcon } from './riso';
import { RisoBoardCell } from './board/RisoBoardCell';
import { BoardPlayCell } from './board/BoardPlayCell';
import { usePlayCellEntries, type PlayTaskEntry } from './board/boardPlayCells';
import { RisoBoardGrid } from './board/RisoBoardGrid';
import { taskCellLabel } from './board/cellModel';
import { useBoardMoment } from './play/useBoardMoment';
import type { FlashOutcome } from './boardPlayFlash';
import { CounterLogToast } from './counters/CounterLogToast';
import { RisoArrivalBanner } from './play/RisoArrivalBanner';
import { EndedBanner } from './boardPlay/EndedBanner';
import { BoardStatusPill } from './boardPlay/BoardStatusPill';
import { BoardLeftStatCard } from './boardPlay/BoardLeftStatCard';
import { BingosStatCard } from './boardPlay/BingosStatCard';
import { LateLogSheet } from './lateLog/LateLogSheet';
import styles from '../pages/BoardPlayPage.module.css';
import play from './play/Play.module.css';

// ─── Constants ────────────────────────────────────────────────────────────────

const FLASH_MS = 3000;

/**
 * Core timeframes that carry a streak (gates the rail's streak chip —
 * CUSTOM / INDEFINITE boards have none). The label is formatted by the shared
 * `compactStreakLabel` so the suffix matches the rest of the app.
 */
const CORE_STREAK_TIMEFRAMES = new Set<string>(['daily', 'weekly', 'monthly', 'yearly']);

/** Human timeframe word for the streak chip's VoiceOver annotation. */
const STREAK_A11Y_WORDS: Record<string, string> = {
  daily: 'daily',
  weekly: 'weekly',
  monthly: 'monthly',
  yearly: 'yearly',
};

// ─── Types ────────────────────────────────────────────────────────────────────

interface FlashMessage {
  // Transient messages only (lost bingo / reactivated / errors); the bingo and
  // greenlog moments are routed to `useBoardMoment` in showFlash.
  text: string;
}

export interface BoardPlaySurfaceProps {
  /** The resolved board to play. Never null/undefined — the container guards loading/not-found. */
  board: Board;
  /** Active user id, used for workspace-wide compound/achievement lookups. */
  userId: string | undefined;
  /** Chrome rendered at the start of the rail's top row (the back
   *  affordance on both the plain page and the pager). */
  header?: React.ReactNode;
  /** Inline accessory rendered beside the kicker line (the pager's
   *  window chip). */
  kickerAccessory?: React.ReactNode;
  /** Rendered under the board grid inside the board column (the pager's
   *  position caption). */
  boardFooter?: React.ReactNode;
  /** Notifies the container when in-place edit mode toggles, so a host
   *  pager can disable window stepping / dim its chip while editing. */
  onEditModeChange?: (editing: boolean) => void;
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
export function BoardPlaySurface({
  board,
  userId,
  header,
  kickerAccessory,
  boardFooter,
  onEditModeChange,
}: BoardPlaySurfaceProps): React.ReactElement {
  // ── Reactive data ──────────────────────────────────────────────────────
  // The read-model (live-query results + derived lookups) is built by
  // `useBoardPlayData` — extracted from this component (B2-W1, issue #270).

  const {
    boardTasks,
    taskMap,
    compoundChildrenByCompound,
    allBoards,
    achievementBadgesByBoardTaskId,
    cellStateByBoardTaskId,
    liveCompletedLineIds,
    sharedCounterSourceIds,
    gridSize,
    btByPosition,
    squareWindowContext,
    sourceTemplate,
    templatesLoaded, boardTasksLoaded,
  } = useBoardPlayData(board, userId);

  // Windowed Completion — sealed boards are a frozen, read-only historical
  // record (docs §Effects of sealed): the grid renders `done` from the stored
  // `sealedCompletedCells` snapshot (not live event queries), and every play
  // interaction (tap, context menu, +, edit entry) is disabled.
  const isSealed = board.sealedAt != null;

  // ── UI state ───────────────────────────────────────────────────────────

  const navigate = useNavigate();
  // Pinned instant for the stat bar's expiry label (shape C).
  const nowPinned = useMemo(() => new Date(), []);
  // Board Edit redesign slice 4 (D12–D16) — "Ended, not closed" (pinned clock).
  const isEnded = isBoardEnded(board, nowPinned.getTime());
  const [flashMessage, setFlashMessage] = useState<FlashMessage | null>(null);
  // The open square sheet: its placement, and the entry a hold-menu item asked for (one state, so every exit clears both).
  const [sheet, setSheet] = useState<{ id: string; entry?: 'add' | 'remove' } | null>(null);
  const closeSheet = (): void => setSheet(null);
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);
  const [openedTaskInLibrary, setOpenedTaskInLibrary] = useState<string | null>(null);
  // D15 — the closed-board direct-log sheet.
  const [lateLogTaskId, setLateLogTaskId] = useState<string | null>(null);
  const flashTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Edit mode: replaces the stats rail with the in-place edit panel. Edit
  // consolidation (D3/D9) — `editSession` carries the squares gate captured
  // ONCE at Edit entry (`canEditSquares`); `editMode` is derived so every
  // existing `editMode`-gated render below is unchanged.
  const [editSession, setEditSession] = useState<{ squaresEditable: boolean } | null>(null);
  const editMode = editSession !== null;
  // "Board saved" green toast shown after a successful edit-mode save.
  const [savedToast, setSavedToast] = useState(false);
  const savedToastTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // The one toast slot (latest wins): a credited-counter ripple (R3) or a
  // Normal tap's "‹title› · done" (docs/TASK_DETAIL_REDESIGN.md §Tap contract).
  const toasts = useSquareToasts();
  const { creditedToast, setCreditedToast } = toasts;
  // Board Edit redesign slice 3 — the squares-editor tap/picker/edit-task
  // overlay state. Owned here (not `useBoardPlay`) since it's pure transient
  // chrome, not draft data.
  const [squareMenu, setSquareMenu] = useState<{
    slot: EditSlot;
    row: number;
    col: number;
    x: number;
    y: number;
  } | null>(null);
  const [pickerState, setPickerState] = useState<
    { mode: 'replace'; cellId: string; row: number; col: number } | { mode: 'add'; row: number; col: number } | null
  >(null);
  const [editTaskSheetId, setEditTaskSheetId] = useState<string | null>(null);
  // D9 — the squares grid's aria-live announcement (Alt+Arrow keyboard moves).
  const [keyboardAnnouncement, setKeyboardAnnouncement] = useState('');

  // The squares-editor staged draft (cells / task overrides / center type /
  // Shuffle / keyboard moves) lives in `useSquaresEditDraft.ts`, composed by
  // `useBoardPlay` below as `editDraft` (Board Edit redesign slice 3). The
  // tap-menu / picker / task-edit-sheet overlay state is pure chrome, owned
  // directly here (`squareMenu` / `pickerState` / `editTaskSheetId` above).
  // `editMode` itself stays here too — set from the JSX Edit button +
  // BoardEditPanel Cancel/Save — and is passed into the hook to drive the
  // draft's seed/reset effect.

  // User preferences (weekStartDay is forwarded to BoardEditPanel + BoardSetupForm).
  const [prefs, , prefsReady] = usePreferences();

  // Repeat-in-edit rework — the repeat controls + spawn-provenance note
  // moved into `BoardEditPanel` (its `BoardEditRepeatSection`), which owns
  // the pools fetch + supply resolution while the panel is open. This
  // surface no longer resolves spawn-note supplies at all.

  // Loose-ends sweep (2026-09-09) — shared-counter family map over the
  // library, for the add/swap picker's one-counter-per-board guard and
  // the spawn note's honest "of M".
  const counterFamilyByTaskId = useMemo(
    () => buildCounterFamilyMap(Object.values(taskMap)),
    [taskMap],
  );

  // Notify the host pager when edit mode toggles (chip dim + step lock).
  useEffect(() => {
    onEditModeChange?.(editMode);
  }, [editMode, onEditModeChange]);

  // D9 belt-and-braces: a Delete from Edit can unmount this whole surface
  // (core pager falls back to its setup prompt) before the effect above
  // re-fires with `editMode=false`. This ref-based cleanup fires
  // `onEditModeChange(false)` unconditionally on unmount — redundant with the
  // explicit call in the Delete `onRemoved` handler below, cheap insurance
  // against the pager's chip/paging staying locked forever.
  const onEditModeChangeRef = useRef(onEditModeChange);
  useEffect(() => {
    onEditModeChangeRef.current = onEditModeChange;
  }, [onEditModeChange]);
  useEffect(() => {
    return () => {
      onEditModeChangeRef.current?.(false);
    };
  }, []);

  // Reset the squares-editor overlay chrome on exit, so re-entering edit
  // mode never flashes a stale menu/picker/task-edit sheet from a prior
  // session (the underlying draft itself resets in `useSquaresEditDraft`).
  useEffect(() => {
    if (!editMode) {
      setSquareMenu(null);
      setPickerState(null);
      setEditTaskSheetId(null);
      setKeyboardAnnouncement('');
    }
  }, [editMode]);

  // Clean up timers on unmount.
  useEffect(() => {
    return () => {
      if (flashTimerRef.current) clearTimeout(flashTimerRef.current);
      if (savedToastTimerRef.current) clearTimeout(savedToastTimerRef.current);
    };
  }, []);

  // ── Derived data ───────────────────────────────────────────────────────
  // achievementBadgesByBoardTaskId, sharedCounterSourceIds,
  // sortedBoardTasks, gridSize, and btByPosition
  // all come from useBoardPlayData above (isEnded/isSealed replaced its
  // isExpired, D12). The edit-mode draft comes from useBoardPlay below.

  // Timeframe greenlog streak (rail chip + the moment's streak chip).
  const streakFor = (t: AchievementTrigger): number =>
    gatedStreak(prefsReady, board.timeframe, t, allBoards, prefs.weekStartDay, nowPinned);
  const greenlogStreak = streakFor(AchievementTrigger.GREENLOG);
  const { open: openMoment, replay: replayMoment, node: momentNode } = useBoardMoment({
    board, boardTasks, taskMap, compoundChildrenByCompound, allBoards, cellStateByBoardTaskId,
    btByPosition, squareWindowContext, gridSize, greenlogStreak, streakFor,
  });

  // ── Flash message helper ───────────────────────────────────────────────

  // Wrapped in useCallback so the function reference is stable across
  // renders. `flashTimerRef` is a stable ref so empty deps is correct.
  // The body writes the ref's `current` to track the active setTimeout
  // handle for cleanup — the `react-hooks/refs` rule
  // (eslint-plugin-react-hooks v7.1+) is conservative about ref access
  // chains; useCallback makes the function's role explicit (event-time,
  // never during render) so the analyzer doesn't flag the call sites.
  const showFlash = useCallback((outcome: FlashOutcome): void => {
    // bingo / greenlog → the full-screen moment; everything else (lost bingo,
    // reactivated, errors) → the transient flash.
    if (outcome.kind !== 'message') {
      openMoment(outcome);
      return;
    }
    if (flashTimerRef.current) clearTimeout(flashTimerRef.current);
    const msg: FlashMessage = { text: outcome.text };
    setFlashMessage(msg);
    flashTimerRef.current = setTimeout(() => {
      setFlashMessage((current) => current === msg ? null : current);
    }, FLASH_MS);
  }, [openMoment]);

  // "Board saved" toast, shared by BoardEditPanel's Save and
  // BoardOptionsSection's Board-details Save (Board Edit redesign slice 2).
  const triggerBoardSavedToast = useCallback((): void => {
    setSavedToast(true);
    if (savedToastTimerRef.current) clearTimeout(savedToastTimerRef.current);
    savedToastTimerRef.current = setTimeout(() => setSavedToast(false), 2400);
  }, []);

  // ── Handler + edit-draft layer ─────────────────────────────────────────
  // The squares-editor draft engine (`editDraft`, Board Edit redesign slice
  // 3 — `useSquaresEditDraft.ts`) and the completion-orchestration handlers
  // live in `useBoardPlay`. It receives the read-model data plus the
  // transient-UI callbacks (`onFlash` = showFlash, `onCreditedToast` =
  // setCreditedToast, and setContextMenu for the error-path menu dismiss).
  const {
    editDraft,
    commitEdits,
    handleComplete,
    handleSharedCounterIncrement,
    handleSharedCounterDecrement,
    undoCreditedToast,
    undoCounterLog,
    handleCompoundChildToggle,
    handleCompoundChildIncrement,
    logStandaloneCount,
    isWriting,
    writeSeq,
    getWriteSeq,
    pendingCounts,
    withPending,
  } = useBoardPlay({
    board,
    editMode,
    boardTasks,
    taskMap,
    compoundChildrenByCompound,
    gridSize,
    // Sealing replaced the expiry lock (docs §Lifecycle): play handlers are
    // locked only on sealed boards; an expired-but-unsealed board stays live.
    playLocked: isSealed,
    squareWindowContext,
    sharedCounterSourceIds,
    onFlash: showFlash,
    onCreditedToast: toasts.onCreditedToast,
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
    windowContext: squareWindowContext,
  });

  // The grid's cell models: derived once per real input change (a toast, a busy
  // flip or a flash re-renders this surface without touching a cell).
  const achievementBoardTaskIds = useMemo(
    () => new Set(Object.keys(achievementBadgesByBoardTaskId)),
    [achievementBadgesByBoardTaskId],
  );
  const cellEntries = usePlayCellEntries({
    board, gridSize, btByPosition, taskMap, compoundChildrenByCompound, cellStateByBoardTaskId, squareWindowContext,
    sharedCounterSourceIds, achievementBoardTaskIds, liveCompletedLineIds, arrivedTaskIds, pendingCounts,
  });

  // Cell handlers read the latest state through a ref, so their identity never
  // changes and the memoised cells below keep skipping renders.
  const tapRef = useRef({ isWriting, handleComplete, tapNormal: toasts.tapNormal, boardLabel: boardDisplayName(board) });
  useEffect(() => {
    tapRef.current = { isWriting, handleComplete, tapNormal: toasts.tapNormal, boardLabel: boardDisplayName(board) };
  });
  const onCellTap = useCallback((entry: PlayTaskEntry): void => {
    // Tap contract (docs/TASK_DETAIL_REDESIGN.md): a Normal square toggles at once + an Undo toast;
    // every other type — and every square on a closed board — opens the square sheet.
    if (!entry.normalTap) {
      setSheet({ id: entry.boardTaskId });
      return;
    }
    const t = tapRef.current;
    if (!t.isWriting) void t.tapNormal(t.handleComplete, { boardTaskId: entry.boardTaskId, ...entry.normalTap, boardLabel: t.boardLabel });
  }, []);
  const onCellHold = useCallback((squareId: string, e: React.MouseEvent): void => {
    setContextMenu({ squareId, x: e.clientX, y: e.clientY });
  }, []);

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

  // Single-square copy needs the arrived square's task name.
  // Resolve the display label (title, or the auto-generated "Action N unit" for
  // a titleless counting task) so a blank-titled counter still reads as "single".
  const arrivalSingle = (() => {
    if (!arrival || arrival.totalArrivedSquares !== 1) return null;
    const taskId = [...arrival.arrivedTaskIds][0];
    const t = taskId ? taskMap[taskId] : undefined;
    const taskName = t ? taskCellLabel(t) : '';
    return { taskName };
  })();

  // ── Render ─────────────────────────────────────────────────────────────

  return (
    <div className={play.play}>
      {/* Bingo / Greenlog moment (+ its share sheet) */}
      {momentNode}

      {/* Arrival banner — passive-completion (Shared Counters P3). Suppressed in
          edit mode (no shared-counter play while editing). */}
      {arrival && !editMode && (
        <RisoArrivalBanner
          key={arrival.key}
          squareCount={arrival.totalArrivedSquares}
          taskName={arrivalSingle?.taskName}
          onOpen={arrivalNav}
          onDismiss={dismissArrival}
        />
      )}

      {/* Credited toast — shared-counter ripple feedback (R3: amount-aware + Undo) */}
      {creditedToast && (
        <CounterLogToast
          key={creditedToast.key}
          text={creditedToast.text}
          detail={creditedToast.detail}
          amount={creditedToast.amount}
          unit=""
          verb={creditedToast.verb}
          counterName={creditedToast.counterName}
          boardNames={creditedToast.boardNames}
          onUndo={async () => {
            // Route through the hook so the reversal flashes any board
            // COMPLETED→ACTIVE / lost-bingo transition it causes (F1); a
            // counts-toward credit's Undo un-completes the task instead. A
            // failed Undo keeps the toast (cleared only on success).
            try {
              await undoCreditedToast(creditedToast);
              setCreditedToast(null);
            } catch (err) {
              console.error('Undo failed', err);
            }
          }}
          onDone={() => setCreditedToast(null)}
        />
      )}

      {/* Transient flash — lost bingo / reactivated / errors (bingo + greenlog
          route to the moment above). */}
      {flashMessage && (
        <div className={styles.flashMessage} role="status" aria-live="polite">
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
            squaresEditable={editSession.squaresEditable}
            editCount={editDraft.editCount}
            canShuffle={editDraft.canShuffle}
            onShuffle={() => editDraft.shuffle()}
            onSaveEdits={commitEdits}
            onCancel={() => setEditSession(null)}
            onSaved={() => {
              setEditSession(null);
              triggerBoardSavedToast();
            }}
          />
        </aside>
      ) : (
        /* Normal play rail: header slot + Edit entry + title + stats + hint */
        <aside className={play.rail}>
          <div className={play.railTop}>
            {header}
            {/* Edit consolidation (D1/D2) — the ONE `Edit` button; every board
                option now lives in Edit's BOARD section (`BoardOptionsSection`,
                rendered by `BoardEditColumn`) — the title-row "…" is retired. */}
            <span className={play.railRight}>
              <BoardEditButton
                board={board}
                onClick={() => setEditSession({ squaresEditable: canEditSquares(board, Date.now()) })}
              />
            </span>
          </div>
          <div>
            <div className={play.kickerRow}>
              <div className={play.kicker}>{board.timeframe.toUpperCase()} BOARD</div>
              {kickerAccessory}
            </div>
            <h2 className={play.title}>{board.name}</h2>
            <div style={{ marginTop: 10, display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
              <BoardStatusPill status={board.status} isSealed={isSealed} isEnded={isEnded} />
              {/* Hidden until resolved — never a state it reverses. */}
              {recurringBadgeState(board, sourceTemplate, templatesLoaded) !== 'hidden' && (
                <RecurringBadge paused={sourceTemplate?.isActive === false} />
              )}
              {greenlogStreak > 0 && CORE_STREAK_TIMEFRAMES.has(board.timeframe) && (
                <span
                  className={play.streakChip}
                  aria-label={`${greenlogStreak} ${STREAK_A11Y_WORDS[board.timeframe] ?? ''} greenlog streak`}
                >
                  <RisoIcon name="flame" size={10} aria-hidden="true" />
                  {compactStreakLabel(greenlogStreak, board.timeframe)} streak
                </span>
              )}
            </div>
          </div>

          {/* Repeat-in-edit rework: the repeat controls (manage row / cadence
              picker) + spawn-provenance note moved into Board Edit's
              REPEATS section (`BoardEditRepeatSection`). */}

          {/* D14 — replaces the old "Board expired…" banner. */}
          {isEnded && !isSealed && <EndedBanner endDate={board.endDate} />}

          <div className={play.statStack}>
            <div className={play.stat}>
              <div className={play.statK}>Squares</div>
              <div className={play.statV}>
                {board.completedTasks}
                <small>/{board.totalTasks}</small>
              </div>
            </div>
            <BoardLeftStatCard
              isSealed={isSealed} isEnded={isEnded} timeframe={board.timeframe}
              endDate={board.endDate} nowPinned={nowPinned}
            />
            <BingosStatCard board={board} onReplay={replayMoment} />
          </div>
        </aside>
      )}

      {/* Board column */}
      <div className={play.boardWrap}>
      {/* Interactive grid */}
      {!boardTasksLoaded ? (
        <p className={styles.emptyState}>Loading board tasks…</p>
      ) : editMode ? (
        // Edit consolidation (plan W2) — the squares editor (or its D4 muted
        // reason line) + the BOARD options section, extracted into
        // `BoardEditColumn` to keep this file under the D11 size cap.
        <BoardEditColumn
          board={board}
          squaresEditable={editSession.squaresEditable}
          editDraft={editDraft}
          gridSize={gridSize}
          announcement={keyboardAnnouncement}
          onOpenPicker={(row, col) => setPickerState({ mode: 'add', row, col })}
          onOpenSquareMenu={(slot, row, col, x, y) => setSquareMenu({ slot, row, col, x, y })}
          onAnnounce={setKeyboardAnnouncement}
          userId={userId}
          sourceTemplate={sourceTemplate}
          templatesLoaded={templatesLoaded}
          weekStartDay={prefs.weekStartDay}
          onDetailsSaved={triggerBoardSavedToast}
          onExitEdit={() => setEditSession(null)}
          onRemoved={() => {
            setEditSession(null);
            onEditModeChange?.(false);
            if (!isCoreBoard(board)) navigate('/boards');
          }}
        />
      ) : (
        <RisoBoardGrid size={gridSize} cellSize={90} className={isSealed ? play.sealedGrid : undefined}>
          {cellEntries.map((entry) => {
            switch (entry.kind) {
              case 'free':
                // The FREE center — pinned, not tappable in play mode.
                return <RisoBoardCell key={entry.key} cell={entry.cell} />;
              case 'empty':
                // D17 retires the play-mode "+" — every structural edit goes through the squares editor.
                return <div key={entry.key} className={styles.emptySquare} />;
              case 'missing':
                return <div key={entry.key} className={styles.emptySquare}>?</div>;
              case 'task':
                return (
                  <BoardPlayCell
                    key={entry.key}
                    entry={entry}
                    cellSize={90}
                    held={contextMenu?.squareId === entry.boardTaskId}
                    onTap={onCellTap}
                    onHold={onCellHold}
                  />
                );
            }
          })}
        </RisoBoardGrid>
      )}

      {/* Host-supplied footer (the pager's position caption). */}
      {boardFooter}

      </div>

      {/* ── Board Edit redesign slice 3 — squares-editor overlays ───────────── */}

      {/* Square tap menu (D7/D13/D16) — shown for EVERY tap: a task-holding
          cell (Replace/Edit/Lock/Remove + "Make it a free space" on the
          NONE center), the pinned FREE center ("Make it a task square"),
          or an empty NONE center ("Add a task…" / "Make it a free space"). */}
      {editMode && squareMenu && (() => {
        const { slot, row, col, x, y } = squareMenu;
        const half = Math.floor(gridSize / 2);
        const isOddBoard = gridSize % 2 === 1;
        const atPositionalCenter = isOddBoard && row === half && col === half;

        if (slot.isEmpty) {
          // An empty NONE center — the only empty slot that opens a menu
          // (a plain empty square jumps straight to the picker, see
          // `BoardEditColumn`'s `onTapSlot` routing).
          return (
            <SquareTapMenu
              taskTitle="Empty square"
              x={x}
              y={y}
              onAdd={() => setPickerState({ mode: 'add', row, col })}
              onMakeFree={() => editDraft.setCenterFree()}
              onClose={() => setSquareMenu(null)}
            />
          );
        }
        if (slot.isCenter) {
          // The pinned FREE center.
          return (
            <SquareTapMenu
              taskTitle="Free space"
              x={x}
              y={y}
              onMakeTask={() => editDraft.setCenterTask()}
              onClose={() => setSquareMenu(null)}
            />
          );
        }
        const cell = editDraft.cellsById[slot.cellId];
        if (!cell) return null;
        const menuTitle = slot.model?.label || '(untitled)';
        return (
          <SquareTapMenu
            taskTitle={menuTitle}
            x={x}
            y={y}
            onReplace={() => setPickerState({ mode: 'replace', cellId: cell.cellId, row, col })}
            onEdit={() => setEditTaskSheetId(cell.taskId)}
            onToggleLock={() => editDraft.toggleLock(cell.cellId)}
            isLocked={cell.isLocked}
            onRemove={() => editDraft.stageRemove(cell.cellId)}
            // The NONE center holding a task also offers "Make it a free space".
            onMakeFree={atPositionalCenter ? () => editDraft.setCenterFree() : undefined}
            onClose={() => setSquareMenu(null)}
          />
        );
      })()}

      {/* Square picker (D13) — the ONE add/replace surface: quick-add row +
          the collapsed special-task panel. */}
      {editMode && pickerState && userId && (() => {
        const currentCell = pickerState.mode === 'replace' ? editDraft.cellsById[pickerState.cellId] : undefined;
        const currentTask = currentCell ? editDraft.resolveTask(currentCell.taskId) : undefined;
        const draftTaskIds = new Set(editDraft.cells.map((c) => c.taskId));
        const candidates = Object.values(taskMap).filter((t) =>
          isSquarePickerCandidate(t, {
            currentTaskId: currentTask?.id,
            placedTaskIds: draftTaskIds,
            counterFamilyByTaskId,
          }),
        );
        return (
          <SquarePickerSheet
            mode={pickerState.mode}
            currentTaskTitle={currentTask ? taskCellLabel(currentTask) : undefined}
            userId={userId}
            timeframe={board.timeframe}
            startDate={board.startDate}
            endDate={board.endDate}
            libraryTasks={candidates} lookupTasks={taskMap}
            onPick={(pick: SquarePick) => {
              if (pickerState.mode === 'replace') {
                editDraft.stageReplace(pickerState.cellId, pick);
              } else {
                editDraft.stageAdd(pickerState.row, pickerState.col, pick);
              }
              setPickerState(null);
            }}
            onClose={() => setPickerState(null)}
          />
        );
      })()}

      {/* Edit-mode Task editor: stages field changes on Done (no DB write); Save forks if placed elsewhere. */}
      {editMode && editTaskSheetId && (() => {
        const sheetTask = editDraft.resolveTask(editTaskSheetId);
        if (!sheetTask) return null;
        return (
          <BoardEditTaskSheet
            task={sheetTask} original={editDraft.resolveOriginalTask(editTaskSheetId)} staged={editDraft.taskOverrides.get(editTaskSheetId)}
            boardId={board.id} forkConfirmed={editDraft.forkConfirmed} onForkConfirmed={editDraft.confirmFork} rootSettings={sheetTask.sharedCounterId ? taskMap[sheetTask.sharedCounterId] : null} goalWindow={board}
            onDone={(taskId, patch) => {
              editDraft.stageTaskEdit(taskId, patch);
              setEditTaskSheetId(null);
            }}
            onCancel={() => setEditTaskSheetId(null)}
          />
        );
      })()}

      {/* Square sheet (tap on Counting / Compound / Achievement, any square on a
          closed board, hold menu's Details) — hidden in edit mode. */}
      {!editMode && sheet && (
        <SquareSheetHost
          key={`${sheet.id}:${sheet.entry ?? ''}`}
          initialEntry={sheet.entry}
          boardTaskId={sheet.id}
          board={board}
          data={{ boardTasks, taskMap, compoundChildrenByCompound, allBoards, achievementBadgesByBoardTaskId, cellStateByBoardTaskId, sharedCounterSourceIds, squareWindowContext, gridSize }}
          play={{ handleComplete, handleSharedCounterIncrement, handleSharedCounterDecrement, undoCounterLog, handleCompoundChildToggle, handleCompoundChildIncrement, logStandaloneCount, isWriting, writeSeq, getWriteSeq, pendingCounts, withPending }}
          quiet={toasts.captureCredits}
          onClose={closeSheet}
          onOpenInLibrary={(taskId) => { closeSheet(); setOpenedTaskInLibrary(taskId); }}
          onLateLog={(taskId) => { closeSheet(); setLateLogTaskId(taskId); }}
          onOpenBoard={(boardId) => { closeSheet(); navigate(`/boards/${boardId}`); }}
          onToggleNormal={(boardTaskId, title, wasDone) => {
            closeSheet();
            const taskId = boardTasks.find((b) => b.id === boardTaskId)?.taskId ?? '';
            if (!isWriting) void toasts.tapNormal(handleComplete, { boardTaskId, taskId, title, wasDone, boardLabel: boardDisplayName(board) });
          }}
        />
      )}

      {/* Task library sheet — "Open in library" from context menu or compound child rows */}
      {!editMode && (
        <TaskDetailSheet
          taskId={openedTaskInLibrary}
          onClose={() => setOpenedTaskInLibrary(null)}
          fromBoardId={board.id}
        />
      )}

      {/* Hold menu — the same vocabulary on every square, open or closed board. */}
      {!editMode && contextMenu && (
        <SquareMenuHost
          squareId={contextMenu.squareId} position={{ x: contextMenu.x, y: contextMenu.y }} board={board}
          data={{ boardTasks, taskMap, compoundChildrenByCompound, allBoards, achievementBadgesByBoardTaskId, cellStateByBoardTaskId, sharedCounterSourceIds, squareWindowContext, gridSize }}
          play={{ handleComplete, handleSharedCounterIncrement, handleSharedCounterDecrement, undoCounterLog, handleCompoundChildToggle, handleCompoundChildIncrement, logStandaloneCount, isWriting, writeSeq, getWriteSeq, pendingCounts, withPending }}
          toasts={toasts} onClose={() => setContextMenu(null)}
          onOpenSheet={(id, entry) => setSheet({ id, entry })}
          onOpenInLibrary={setOpenedTaskInLibrary} onLateLog={setLateLogTaskId}
          onOpenBoard={(id) => navigate(`/boards/${id}`)}
        />
      )}

      {/* D17 — the play-mode "+" add-to-empty-cell modal is retired. Every
          structural edit (add/replace/remove/move/lock) goes through the
          squares editor now. */}

      {/* D15 — the closed-board direct-log sheet. */}
      {isSealed && lateLogTaskId && taskMap[lateLogTaskId] && (() => { const lateLogBt = boardTasks.find((b) => b.taskId === lateLogTaskId && !b.isDeleted); return ( // slice 2a
        <LateLogSheet board={board} task={(lateLogBt && placedTaskFor(lateLogBt, taskMap)) ?? taskMap[lateLogTaskId]} taskMap={taskMap}
          compoundChildrenByCompound={compoundChildrenByCompound} childTargets={lateLogBt?.childTargets} onClose={() => setLateLogTaskId(null)} />
      ); })()}

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
