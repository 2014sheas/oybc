import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AchievementTrigger,
  CenterSquareType,
  TaskType,
  buildCounterFamilyMap,
  effectiveCenter,
  isBoardEnded,
  isLegacyChosenCenterLocked,
  isWindowStampedDerived,
  type Board,
  type Task,
} from '@oybc/shared';
import {
  useBoardPlayData,
  useBoardPlay,
  useCounterArrivals,
  type FlashVariant,
  type CreditedToast,
} from '../hooks';
import { resolveClosedBoardCounterDisplay, taskToSquareData, taskToSquareState } from '../db/adapters';
import {
  DetailModal,
  FloatingContextMenu,
} from './InteractiveTaskSquare';
import type { ContextMenuState } from './interactiveTaskSquareUtils';
import {
  resolveSharedCounterDefaultAmount,
  resolveSharedCounterSourceId,
} from './boardPlaySharedCounterUtils';
import { setCounterDefaultLogAmount } from '../db/operations/tasks';
import { useCountingLogModal } from './boardPlay/useCountingLogModal';
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
  boardSheetChips, compactStreakLabel, getHighlightedSquares, quantizeCount, quickLogAmount, resolveFamilyCountKind,
} from '@oybc/shared';
import { gatedStreak } from '../utils/gatedStreak';
import { RisoIcon } from './riso';
import { RisoBoardCell } from './board/RisoBoardCell';
import { RisoBoardGrid } from './board/RisoBoardGrid';
import { freeCellModel, taskCellLabel, toBoardCellModel } from './board/cellModel';
import { RisoBingoToast } from './play/RisoBingoToast';
import { RisoGreenlog } from './play/RisoGreenlog';
import { CounterLogToast } from './counters/CounterLogToast';
import { RisoArrivalBanner } from './play/RisoArrivalBanner';
import { ShareBoardSheet } from './share/ShareBoardSheet';
import { EndedBanner } from './boardPlay/EndedBanner';
import { BoardStatusPill } from './boardPlay/BoardStatusPill';
import { BoardLeftStatCard } from './boardPlay/BoardLeftStatCard';
import { LateLogSheet } from './lateLog/LateLogSheet';
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

/** Human timeframe word for the streak chip's VoiceOver annotation. */
const STREAK_A11Y_WORDS: Record<string, string> = {
  daily: 'daily',
  weekly: 'weekly',
  monthly: 'monthly',
  yearly: 'yearly',
};

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
  const sealedCellSet = useMemo(
    () => new Set(isSealed ? (board.sealedCompletedCells ?? []) : []),
    [isSealed, board.sealedCompletedCells],
  );

  // ── UI state ───────────────────────────────────────────────────────────

  const navigate = useNavigate();
  // Pinned instant for the stat bar's expiry label (shape C).
  const nowPinned = useMemo(() => new Date(), []);
  // Board Edit redesign slice 4 (D12–D16) — "Ended, not closed" (pinned clock).
  const isEnded = isBoardEnded(board, nowPinned.getTime());
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
  // Phase 2 — Shared Counters: credited toast shown after an increment/decrement
  // that ripples to OTHER boards. The `key` field forces CounterLogToast to
  // remount (resetting its timer) when consecutive logs fire quickly.
  // R3: amount-aware + Undo — shape matches `useBoardPlay`'s `CreditedToast`.
  const [creditedToast, setCreditedToast] = useState<CreditedToast | null>(null);
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
      if (bingoTimerRef.current) clearTimeout(bingoTimerRef.current);
      if (savedToastTimerRef.current) clearTimeout(savedToastTimerRef.current);
    };
  }, []);

  // ── Derived data ───────────────────────────────────────────────────────
  // achievementBadgesByBoardTaskId, sharedCounterSourceIds,
  // sortedBoardTasks, gridSize, and btByPosition
  // all come from useBoardPlayData above (isEnded/isSealed replaced its
  // isExpired, D12). The edit-mode draft comes from useBoardPlay below.

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
    undoCounterLog,
    handleCompoundChildToggle,
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
    onFlash: showFlash,
    onCreditedToast: setCreditedToast,
    setContextMenu,
  });

  // Counter kinds §5 — the detail modal's log-amount controls (chips + amount
  // field), in `useCountingLogModal`; the count is the modal's windowed value.
  const quickAmount = useCountingLogModal(selectedSquareId, (btId) => {
    const bt = boardTasks.find((b) => b.id === btId);
    const task = bt ? taskMap[bt.taskId] : undefined;
    if (!bt || !task || task.type !== TaskType.COUNTING) return null;
    const children = compoundChildrenByCompound[task.id] ?? [];
    return {
      boardTaskId: btId, task, taskMap, isSealed,
      sourceId: resolveSharedCounterSourceId(task, sharedCounterSourceIds),
      currentCount: taskToSquareState(task, children, taskMap, compoundChildrenByCompound, squareWindowContext, cellStateByBoardTaskId[btId]).currentCount,
      onIncrementShared: (s, a, p) => void handleSharedCounterIncrement(s, a, p),
      onDecrementShared: (s, a, p) => void handleSharedCounterDecrement(s, a, p),
      onSetStandaloneCount: (b, next) => void handleComplete(b, { currentCount: next }),
      onPersistDefault: (id, a) => void setCounterDefaultLogAmount(id, a).catch((err) => console.error('Persist default log amount failed:', err)),
    };
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
    const taskName = t ? taskCellLabel(t) : '';
    const counterName = arrival.arrivedCounters[0]?.counterName ?? '';
    return { taskName, counterName };
  })();

  // ── Render ─────────────────────────────────────────────────────────────

  // Compute streak once so both RisoGreenlog and ShareBoardSheet use the same value.
  const greenlogStreak = gatedStreak(
    prefsReady, board.timeframe, AchievementTrigger.GREENLOG,
    allBoards, prefs.weekStartDay, nowPinned,
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
            // Await-then-clear like R2's Hub/Detail callers (#342 review M3):
            // a failed undo must not leave the user believing it succeeded.
            void (async () => {
              try {
                // Route through the hook so the reversal flashes any board
                // COMPLETED→ACTIVE / lost-bingo transition it causes (F1).
                await undoCounterLog(sourceTaskId);
              } catch (err) {
                console.error('Undo failed', err);
              } finally {
                setCreditedToast(null);
              }
            })();
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
            <div className={`${play.stat} ${play.gold}`}>
              <div className={play.statK}>Bingos</div>
              <div className={play.statV}>
                <span className={play.starS} aria-hidden="true" />
                {board.linesCompleted}
              </div>
            </div>
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
            if (!board.isCore) navigate('/boards');
          }}
        />
      ) : (
        <RisoBoardGrid size={gridSize} cellSize={90} className={isSealed ? play.sealedGrid : undefined}>
          {(() => {
            const cells: React.ReactElement[] = [];
            // Gold-ring the cells in completed bingo lines. Board-integrity
            // PR-3, Part 3 (ring coherence): a LIVE (unsealed) board rings
            // from `liveCompletedLineIds` — detected from the SAME kernel
            // grid `cellStateByBoardTaskId` was built from THIS render —
            // rather than `board.completedLineIds`, whose write lags one
            // cascade transaction behind the reactive grid. A SEALED board
            // keeps its frozen `completedLineIds` snapshot (the permanent
            // read-only record; never re-derived live).
            const highlightedSquares = getHighlightedSquares(
              isSealed ? (board.completedLineIds ?? []) : liveCompletedLineIds,
              gridSize,
            );

            for (let row = 0; row < gridSize; row++) {
              for (let col = 0; col < gridSize; col++) {
                const posKey = `${row}-${col}`;
                const isCenter =
                  gridSize % 2 === 1 &&
                  row === Math.floor(gridSize / 2) &&
                  col === Math.floor(gridSize / 2);

                // Board Edit slice 3 (D1) — a live board reads its center
                // through `effectiveCenter` (CHOSEN → NONE); a legacy-CHOSEN
                // center is a normal (task-square, effectively-locked) cell,
                // never pinned.
                const centerType = board.centerSquareType as CenterSquareType;
                const isFreeCenter = isCenter && effectiveCenter(centerType) === CenterSquareType.FREE;

                const bt = btByPosition[posKey];
                const boardTaskId = bt?.id;
                const resolvedTaskId = bt?.taskId;

                // ── Empty / center cells ─────────────────────────────────
                if (!boardTaskId) {
                  if (isFreeCenter) {
                    // The FREE center — pinned, not tappable in play mode.
                    cells.push(
                      <RisoBoardCell key={`center-${row}-${col}`} cell={freeCellModel(`center-${row}-${col}`)} />
                    );
                  } else {
                    // Empty cell (non-center, or a NONE center with no task).
                    // D17 retires the play-mode "+" — every structural edit
                    // now goes through the squares editor.
                    cells.push(
                      <div key={`empty-${row}-${col}`} className={styles.emptySquare} />
                    );
                  }
                  continue;
                }

                // ── Resolve the base task from taskMap ───────────────────
                const task: Task | undefined = resolvedTaskId ? taskMap[resolvedTaskId] : undefined;
                if (!task) {
                  cells.push(
                    <div key={`missing-${boardTaskId}`} className={styles.emptySquare}>?</div>
                  );
                  continue;
                }

                const taskChildren = compoundChildrenByCompound[task.id] ?? [];
                // Board-integrity PR-3 — the kernel's per-cell resolution for
                // THIS placement (achievement completion has no other source).
                const cellState = boardTaskId ? cellStateByBoardTaskId[boardTaskId] : undefined;
                const squareData = taskToSquareData(
                  task, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
                );
                const squareState = taskToSquareState(
                  task, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext, cellState,
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
                // D16 — a CLOSED counting square shows the sealed-bounded
                // WINDOWED count (e.g. "3/5"), same bound `taskIsCompleted` used.
                const taskCurrentCount = isSealed
                  ? squareData.type === 'counting'
                    ? resolveClosedBoardCounterDisplay(task, squareWindowContext.eventsByTaskId, board).displayed
                    : 0
                  : squareState.currentCount;

                // Phase 2 — Shared Counters: mark the cell as shared when
                // it is a source OR a linked derived counter, so the
                // two-dot ↔ marker appears on the grid while not done.
                const isSharedCountingTask =
                  squareData.type === 'counting' &&
                  !taskIsCompleted &&
                  (task.sharedCounterId != null || sharedCounterSourceIds.has(task.id));

                // Board Edit redesign slice 3 (D1) — the lock chip reflects
                // the EFFECTIVE lock: a stored lock, or a legacy-CHOSEN
                // board's positional center (not yet normalized on disk).
                const effectiveLocked =
                  bt?.isLocked === true || isLegacyChosenCenterLocked(centerType, row, col, gridSize);

                const cellModel = toBoardCellModel({
                  key: boardTaskId,
                  task,
                  done: taskIsCompleted,
                  currentCount: squareData.type === 'counting' ? taskCurrentCount : undefined,
                  isLine: highlightedSquares.has(row * gridSize + col),
                  isShared: isSharedCountingTask,
                  // Phase 3 — pulse squares that just filled in from an elsewhere log.
                  isArrived: resolvedTaskId != null && arrivedTaskIds.has(resolvedTaskId),
                  locked: effectiveLocked,
                  countKind: resolveFamilyCountKind(task, (id) => taskMap[id]),
                });

                // ── Click handler (play mode) ────────────────────────────
                // Sealing REPLACES the old expiry-based interaction lock
                // (docs §Lifecycle: an expired-but-unsealed board is "still
                // fully live" — the closing-out banner's Log action opens it
                // to log late activity; the backstop bounds the overtime).
                const handlePlayClick = !isSealed
                  ? () => {
                      // Board-integrity PR-3 (issue #360, finding 2) —
                      // Achievement squares are read-only on the grid; tap
                      // is a no-op (mirrors iOS `case .achievement: break`).
                      // Detail is reachable via the context-menu "View
                      // Details" item (falls through FloatingContextMenu's
                      // type switch to the common item), never a plain tap.
                      if (squareData.type === 'achievement') {
                        return;
                      }
                      // Counter kinds §5 — every counting tap opens the modal
                      // (web Discrete no longer logs +1 on tap).
                      if (squareData.type === 'compound' || squareData.type === 'counting') {
                        setSelectedSquareId(boardTaskId);
                      } else {
                        void handleComplete(boardTaskId, {
                          isCompleted: !taskIsCompleted,
                        });
                      }
                    }
                  : () => {
                      // D15 — closed-board tap opens the late-log sheet;
                      // achievement / hub-linked derived (OQ2) stay a no-op.
                      const hubLinked = squareData.type === 'counting'
                        && task.sharedCounterId != null && !isWindowStampedDerived(task);
                      if (squareData.type === 'achievement' || hubLinked) return;
                      setLateLogTaskId(task.id);
                    };

                cells.push(
                  <RisoBoardCell
                    key={boardTaskId}
                    cell={cellModel}
                    cellSize={90}
                    badge={
                      achievementBadgesByBoardTaskId[boardTaskId] ? (
                        <span className={play.achvBadge} title="Achievement">
                          A
                        </span>
                      ) : undefined
                    }
                    onClick={handlePlayClick}
                    onContextMenu={(e) => {
                      if (isSealed) return;
                      e.preventDefault();
                      setContextMenu({ squareId: boardTaskId, x: e.clientX, y: e.clientY });
                    }}
                  />,
                );
              }
            }

            return cells;
          })()}
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
            libraryTasks={candidates}
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

      {/* Edit-mode Task editor: opens BoardEditTaskSheet to stage field changes.
          On Done, stages the patch in taskOverrides (no DB write). */}
      {editMode && editTaskSheetId && (() => {
        const sheetTask = editDraft.resolveTask(editTaskSheetId);
        if (!sheetTask) return null;
        return (
          <BoardEditTaskSheet
            task={sheetTask} original={editDraft.resolveOriginalTask(editTaskSheetId)} staged={editDraft.taskOverrides.get(editTaskSheetId)}
            onDone={(taskId, patch) => {
              editDraft.stageTaskEdit(taskId, patch);
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
          task, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
        );
        const squareState = taskToSquareState(
          task, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
          cellStateByBoardTaskId[bt.id],
        );
        // Use squareState.currentCount (baseline-adjusted for linked counters)
        // rather than the raw task.currentCount accumulator. For standalone
        // counters the two values are identical; for linked derived counters
        // taskToSquareState has already applied deriveDisplayedCount.
        const modalCurrentCount = squareState.currentCount;

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
              // Standalone Discrete squares only — every other counting square
              // routes through `quickAmount.onAdd`.
              if (isSealed) return;
              void handleComplete(bt.id, { currentCount: modalCurrentCount + 1 });
            }}
            onDecrementCount={() => {
              // Standalone Discrete squares only — every other counting square
              // routes through `quickAmount.onRemove`.
              if (isSealed) return;
              if (modalCurrentCount > 0) void handleComplete(bt.id, { currentCount: modalCurrentCount - 1 });
            }}
            onCompoundChildToggle={
              squareData.type === 'compound' ? handleCompoundChildToggle : undefined
            }
            onOpenInLibrary={(taskId) => { setSelectedSquareId(null); setOpenedTaskInLibrary(taskId); }}
            quickAmount={quickAmount}
            achievementBadge={achievementBadgesByBoardTaskId[bt.id]}
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
          task, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
        );
        const squareState = taskToSquareState(
          task, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
          cellStateByBoardTaskId[bt.id],
        );
        // Use squareState.currentCount (baseline-adjusted for linked counters).
        const menuCurrentCount = squareState.currentCount;
        // Linked derived counters are read-only — decrement/reset must be gated.
        const isLinkedCounter = squareData.sharedCounterId != null;

        // R3 — quick-action amount options (shared counting squares only).
        // The "# Custom amount…" item opens the detail modal (which owns
        // the full picker) rather than an inline input — see the prop's
        // docstring on `FloatingContextMenu` for why.
        const menuSourceId = resolveSharedCounterSourceId(task, sharedCounterSourceIds);
        const menuKind = resolveFamilyCountKind(task, (id) => taskMap[id]);
        const amountActions = squareData.type === 'counting' && menuKind !== 'discrete'
          ? {
              kind: menuKind,
              amount: quickLogAmount(
                menuKind, boardSheetChips(menuKind, task.maxCount ?? 0),
                (menuSourceId ? taskMap[menuSourceId] : task)?.defaultLogAmount,
              ),
              unit: task.unit ?? '',
              onAdd: (a: number) => (menuSourceId
                ? void handleSharedCounterIncrement(menuSourceId, a, false)
                : void handleComplete(bt.id, { currentCount: quantizeCount(menuCurrentCount + a) })),
              onRemove: (a: number) => (menuSourceId
                ? void handleSharedCounterDecrement(menuSourceId, a, false)
                : void handleComplete(bt.id, { currentCount: Math.max(0, quantizeCount(menuCurrentCount - a)) })),
              onOpenCustom: () => setSelectedSquareId(bt.id),
              removeDisabled: isLinkedCounter || menuCurrentCount <= 0,
            }
          : undefined;
        const sharedAmountActions =
          squareData.type === 'counting' && menuSourceId && menuKind === 'discrete'
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
              // R3: mirror the ADD amount (the counter's default) per the
              // contract "decrement mirrors the add amount" — matches iOS's
              // context menu and this menu's own remove label.
              if (sharedCounterSourceIds.has(task.id)) {
                void handleSharedCounterDecrement(
                  task.id,
                  resolveSharedCounterDefaultAmount(task),
                );
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
            sharedAmountActions={sharedAmountActions}
            amountActions={amountActions}
          />
        );
      })()}

      {/* D17 — the play-mode "+" add-to-empty-cell modal is retired. Every
          structural edit (add/replace/remove/move/lock) goes through the
          squares editor now. */}

      {/* D15 — the closed-board direct-log sheet. */}
      {isSealed && lateLogTaskId && taskMap[lateLogTaskId] && (
        <LateLogSheet
          board={board} task={taskMap[lateLogTaskId]} taskMap={taskMap}
          compoundChildrenByCompound={compoundChildrenByCompound}
          onClose={() => setLateLogTaskId(null)}
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
