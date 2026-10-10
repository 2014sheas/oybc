import { useCallback } from 'react';
import {
  BoardStatus,
  TaskType,
  counterDisplayName,
  countsTowardAmountOf,
  effectiveCenter,
  resolveTaskWindowState,
  type Board,
  type BoardSize,
  type BoardTask,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { db } from '../db/internal';
import { compoundChildToggleDesired, type SquareWindowContext } from '../db/adapters';
import { handleTaskCompletion } from '../db/operations/orchestration';
import { creditedBoardsForCounter } from '../db/operations/countsToward';
import { fetchTask } from '../db/operations/tasks';
import {
  decrementSharedCounter,
  incrementSharedCounter,
  setCounterDefaultLogAmount,
} from '../db/operations/tasks';
import { resolveCreditedCounterName } from '../components/boardPlaySharedCounterUtils';
import { deriveFlashOutcome } from '../components/boardPlayFlash';
import { toggleCompoundChildFallback, undoLastCounterLog } from '../db/operations/tasks';
import { commitSquareEdits } from '../db/operations/boardEditCommit';
import type { ContextMenuState } from '../components/interactiveTaskSquareUtils';
import { useSquaresEditDraft, type UseSquaresEditDraftResult } from './useSquaresEditDraft';

/** What a counts-toward completion needs for its credited toast. */
interface CountsTowardCredit {
  task: Task;
  boardTaskId: string;
  /** The write that puts the square back (the toast's Undo). */
  revert: { isCompleted?: boolean; currentCount?: number };
}

/**
 * "Counts toward" (docs/SHARED_COUNTER_SETTINGS.md §3d, design handoff §C4):
 * when a write completes a CONTRIBUTING square — a Simple task checked off,
 * or a plain Counting one reaching its goal, judged against the board's
 * window (`ctx`, the pre-write snapshot) — the credited toast fires under
 * today's trigger (the counter has squares on OTHER boards). Returns what
 * the toast needs, or `null`.
 */
export function countsTowardCreditPreview(
  boardTaskId: string,
  updates: { isCompleted?: boolean; currentCount?: number },
  boardTasks: ReadonlyArray<BoardTask>,
  taskMap: Record<string, Task>,
  ctx: SquareWindowContext,
): CountsTowardCredit | null {
  const bt = boardTasks.find((b) => b.id === boardTaskId);
  const task = bt ? taskMap[bt.taskId] : undefined;
  if (!task || task.countsTowardCounterId == null || task.sharedCounterId != null) return null;
  const before = resolveTaskWindowState(task, ctx.eventsByTaskId[task.id] ?? [], ctx.windowStart, ctx.windowEnd);
  if (before.isCompleted) return null;
  if (task.type === TaskType.NORMAL && updates.isCompleted === true) return { task, boardTaskId, revert: { isCompleted: false } };
  if (task.type === TaskType.COUNTING && updates.currentCount != null && task.maxCount != null && updates.currentCount >= task.maxCount) {
    return { task, boardTaskId, revert: { currentCount: before.count } };
  }
  return null;
}

/** The credited toast for a counts-toward completion, or `null` when the counter has no squares on other boards. */
async function countsTowardCreditToast(credit: CountsTowardCredit, boardId: string): Promise<CreditedToast | null> {
  const rootId = credit.task.countsTowardCounterId as string;
  const [root, otherBoards] = await Promise.all([fetchTask(rootId), creditedBoardsForCounter(rootId, boardId, new Date())]);
  if (!root || root.isDeleted || otherBoards.length === 0) return null;
  return {
    sourceTaskId: rootId,
    counterName: counterDisplayName(root),
    amount: countsTowardAmountOf(credit.task),
    verb: 'logged',
    boardNames: otherBoards.map((b) => b.boardName),
    key: Date.now(),
    undo: { kind: 'uncomplete', boardTaskId: credit.boardTaskId, updates: credit.revert },
  };
}

/** What `onFlash` is called with. `greenlog` routes to the overlay and a
 *  new bingo to the toast; only the residual cases reach the transient flash. */
export type FlashVariant = 'bingo' | 'greenlog';

/**
 * Credited-toast payload shown after a shared-counter log ripples to OTHER
 * boards (R3 — amount-aware + Undo; `sourceTaskId` lets the toast's Undo
 * pill call `undoLastCounterLog`, which reverses the counter's LATEST live
 * entry at tap time — normally the one this toast displays, but a log from
 * another surface/device during the toast window would be reversed instead;
 * accepted single-user race, same semantics as R2's Hub/Detail Undo — see
 * docs/SHARED_COUNTERS.md §R3).
 */
export interface CreditedToast {
  /** The shared counter's source task id — what `undoLastCounterLog` reverses. */
  sourceTaskId: string;
  /**
   * What Undo does. A hand log reverses the counter's latest entry
   * (`counterLog`); a counts-toward credit is cascade-derived, so its Undo
   * UN-COMPLETES the contributing square (`uncomplete`: the write that puts
   * it back) and the cascade tombstones the credit. Absent = `counterLog`.
   */
  undo?: { kind: 'counterLog' } | { kind: 'uncomplete'; boardTaskId: string; updates: { isCompleted?: boolean; currentCount?: number } };
  /** Pair-derived counter name (`resolveCreditedCounterName`), never raw `task.title`. */
  counterName: string;
  /** The amount actually applied (for a decrement, the clamped `effectiveDelta`) — matches what Undo will reverse. */
  amount: number;
  verb: 'logged' | 'removed';
  boardNames: string[];
  key: number;
}

/**
 * Inputs to `useBoardPlay`. The read-model fields (`boardTasks`, `taskMap`,
 * …) come straight from `useBoardPlayData`; the callbacks (`onFlash`,
 * `onCreditedToast`, `setContextMenu`) let the handlers drive the transient
 * UI (flash / credited toast / context-menu dismissal) that stays owned by
 * `BoardPlaySurface`.
 */
export interface UseBoardPlayParams {
  board: Board;
  /** Whether the board is currently in in-place edit mode (owned by the
   *  component — pure chrome; drives the draft seed/reset effect). */
  editMode: boolean;
  boardTasks: BoardTask[];
  taskMap: Record<string, Task>;
  compoundChildrenByCompound: Record<string, CompoundChild[]>;
  gridSize: BoardSize;
  /**
   * Whether play-mode write handlers are locked. Windowed Completion (docs
   * §Effects of sealed / §Lifecycle): the caller passes `board.sealedAt !=
   * null` — sealing REPLACED the old expiry-based lock, so an
   * expired-but-unsealed board stays fully live until it seals (the
   * closing-out banner's Log action depends on this).
   */
  playLocked: boolean;
  /**
   * Windowed Completion (docs/WINDOWED_COMPLETION.md §Semantics): the board's
   * window context (from `useBoardPlayData`/`useSquareWindowContext`), threaded
   * into the squares-editor's `taskToSquareState`/`taskToSquareData` calls so
   * a lifetime-complete task on a fresh window's board previews grey, matching
   * the real grid (BoardPlaySurface's own render already does this).
   */
  squareWindowContext: SquareWindowContext;
  /** Show a transient flash / bingo toast / greenlog overlay (component's `showFlash`). */
  onFlash: (text: string, variant: FlashVariant) => void;
  /** Show the shared-counter credited toast (component's `setCreditedToast`). */
  onCreditedToast: (toast: CreditedToast) => void;
  /** Dismiss the floating context menu (component's `setContextMenu`). */
  setContextMenu: React.Dispatch<React.SetStateAction<ContextMenuState | null>>;
}

/** Everything `BoardPlaySurface` needs from the handler/edit-draft layer. */
export interface UseBoardPlayResult {
  /** Board Edit redesign slice 3 (T2) — the squares-editor draft engine. */
  editDraft: UseSquaresEditDraftResult;
  /** Commits the whole staged squares-editor session (D15, ONE transaction). */
  commitEdits: () => Promise<void>;
  // ── Completion handlers ──
  handleComplete: (
    boardTaskId: string,
    updates: { isCompleted?: boolean; currentCount?: number; completedStepIds?: string[] },
  ) => Promise<void>;
  /**
   * @param sourceTaskId - The shared counter's source task id.
   * @param amount - Amount to log (default 1 — back-compat for the plain
   *   grid tap on a standalone counting task's shared-counter path). R3
   *   callers (grid tap / detail modal / context menu) pass the resolved
   *   amount explicitly — see `resolveSharedCounterDefaultAmount`.
   * @param persistAsDefault - When true, also persists `amount` as the
   *   counter's new `defaultLogAmount` (R3: only an explicit custom `#`
   *   amount persists — one-tap chips/plain-tap paths pass `false`).
   */
  handleSharedCounterIncrement: (
    sourceTaskId: string,
    amount?: number,
    persistAsDefault?: boolean,
  ) => Promise<void>;
  /** Mirrors `handleSharedCounterIncrement` — see its param docs. */
  handleSharedCounterDecrement: (
    sourceTaskId: string,
    amount?: number,
    persistAsDefault?: boolean,
  ) => Promise<void>;
  /**
   * Reverse the most recent shared-counter log for a source task (the
   * credited-toast Undo pill), flashing any board COMPLETED→ACTIVE / lost-bingo
   * transition the reversal causes (F1 — mirrors `handleSharedCounterDecrement`).
   * May throw (invalid source); the caller owns the toast-dismiss + error path.
   */
  undoCounterLog: (sourceTaskId: string) => Promise<void>;
  /** The credited toast's Undo: reverses a hand log, or un-completes a counts-toward contributor. */
  undoCreditedToast: (toast: CreditedToast) => Promise<void>;
  handleCompoundChildToggle: (childTaskId: string) => Promise<void>;
}

/**
 * The handler + edit-draft layer for playing a board. Board Edit redesign
 * slice 3 (T2): the staged squares-edit draft moved OUT of this file
 * entirely into `useSquaresEditDraft.ts` (position-keyed, staged-ADD-aware,
 * Shuffle, Free⇄Task center, keyboard moves — replacing the slice-1/2
 * Edit-tasks ⇄ Rearrange sub-mode split); this hook now only composes it,
 * builds the Save transaction's input, and keeps the completion-orchestration
 * handlers (unchanged from B2-W3, issue #270). The play-mode "+" / add-modal
 * write path is retired (D17) — every structural edit goes through the
 * squares editor now.
 *
 * @param params - Read-model data (from `useBoardPlayData`) plus the transient-UI callbacks.
 */
export function useBoardPlay(params: UseBoardPlayParams): UseBoardPlayResult {
  const {
    board,
    editMode,
    boardTasks,
    taskMap,
    compoundChildrenByCompound,
    gridSize,
    playLocked,
    squareWindowContext,
    onFlash,
    onCreditedToast,
    setContextMenu,
  } = params;
  const boardId = board.id;

  const editDraft = useSquaresEditDraft({
    board,
    editMode,
    boardTasks,
    taskMap,
    compoundChildrenByCompound,
    gridSize,
    squareWindowContext,
  });

  /**
   * Commits the whole staged squares-editor session in ONE Dexie transaction
   * (D15, `boardEditCommit.ts`). Builds the removal list from the LIVE
   * `boardTasks` snapshot vs the draft's tracked removals (a cell absent from
   * the draft only counts if it was a live placement at seed time — a staged
   * add that got removed again leaves no trace), and the center metadata
   * patch only when the effective center type actually changed (FREE ⇄ NONE
   * only — CHOSEN is never written post-slice-3, D1/D16).
   */
  const commitEdits = useCallback(async (): Promise<void> => {
    const effectiveDraftCenter = effectiveCenter(editDraft.draftCenterType);
    const effectiveBoardCenter = effectiveCenter(board.centerSquareType);
    const centerPatch =
      effectiveDraftCenter !== effectiveBoardCenter
        ? { centerSquareType: effectiveDraftCenter }
        : undefined;

    await commitSquareEdits({
      boardId,
      cells: editDraft.cells,
      removedBoardTaskIds: editDraft.removedBoardTaskIds,
      taskOverrides: editDraft.taskOverrides,
      isLegacyChosenOnDisk: editDraft.isLegacyChosenOnDisk,
      centerCellKeepLocked: editDraft.centerCellKeepLocked,
      centerPatch,
    });
  }, [boardId, board.centerSquareType, editDraft]);

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
        const credit = countsTowardCreditPreview(boardTaskId, updates, boardTasks, taskMap, squareWindowContext);
        const result = await handleTaskCompletion(boardId, boardTaskId, updates);
        if (credit) {
          const toast = await countsTowardCreditToast(credit, boardId);
          if (toast) onCreditedToast(toast);
        }
        // Priority: reactivated > lostBingos > greenlog > newBingos — shared
        // ladder lives in `deriveFlashOutcome` (issue #270, B2-W2 dedup).
        //
        // Feed `boardCompleted` (the not-complete→complete TRANSITION signal),
        // NOT the ungated `result.isGreenlog` (issue #272) — `isGreenlog` stays
        // true on every subsequent write to an already-COMPLETED board (e.g.
        // overshooting a counting task past its goal), which would re-fire the
        // GREENLOG celebration with no actual transition. Matches
        // `handleSharedCounterIncrement`'s `wasActive && isNowCompleted &&
        // isGreenlogRaw` gate below, and iOS's `didAutoComplete` semantics.
        const outcome = deriveFlashOutcome({
          boardReactivated: result.boardReactivated,
          lostBingos: result.lostBingos,
          isGreenlog: result.boardCompleted,
          newBingos: result.newBingos,
        });
        if (outcome) onFlash(outcome.text, outcome.variant);
      } catch (err) {
        console.error('Task completion failed:', err);
        onFlash('Something went wrong', 'bingo');
        setContextMenu(null);
      }
    },

    [boardId, onFlash, setContextMenu, boardTasks, taskMap, squareWindowContext, onCreditedToast]
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
   * R3 — amount-aware: `amount` (default 1) is the actual units logged;
   * when `persistAsDefault` is set, the amount also becomes the counter's
   * new `defaultLogAmount` (custom "#" amounts only — see the param docs
   * on `UseBoardPlayResult.handleSharedCounterIncrement`).
   *
   * @param sourceTaskId - The source (template) task id to increment.
   * @param amount - Units to log (default 1).
   * @param persistAsDefault - Persist `amount` as the new default (default false).
   */
  const handleSharedCounterIncrement = useCallback(
    async (sourceTaskId: string, amount = 1, persistAsDefault = false): Promise<void> => {
      if (playLocked) return;
      try {
        // Capture the pre-increment board stats for flash comparison.
        const boardBefore = await db.boards.get(boardId);
        const { affectedBoards } = await incrementSharedCounter(sourceTaskId, amount, boardId);
        if (persistAsDefault) {
          await setCounterDefaultLogAmount(sourceTaskId, amount);
        }
        // Re-fetch to get post-increment board state.
        const boardAfter = await db.boards.get(boardId);
        if (!boardBefore || !boardAfter) return;

        const prevBingos = new Set(boardBefore.completedLineIds ?? []);
        const nextBingos = new Set(boardAfter.completedLineIds ?? []);
        const newBingos = [...nextBingos].filter((id) => !prevBingos.has(id));
        const lostBingos = [...prevBingos].filter((id) => !nextBingos.has(id));
        const totalSquares = boardAfter.boardSize * boardAfter.boardSize;
        const isGreenlogRaw = boardAfter.completedTasks >= totalSquares;
        const wasActive = boardBefore.status === BoardStatus.ACTIVE;
        const isNowCompleted = boardAfter.status === BoardStatus.COMPLETED;
        const wasCompleted = boardBefore.status === BoardStatus.COMPLETED;
        const isNowActive = boardAfter.status === BoardStatus.ACTIVE;

        // Same shared ladder as handleComplete (`deriveFlashOutcome`), fed
        // from a before/after snapshot diff instead of a TaskCompletionResult
        // — see boardPlayFlash.ts for why the two derivations differ here.
        const outcome = deriveFlashOutcome({
          boardReactivated: wasCompleted && isNowActive,
          lostBingos,
          isGreenlog: wasActive && isNowCompleted && isGreenlogRaw,
          newBingos,
        });
        if (outcome) onFlash(outcome.text, outcome.variant);

        // Credited toast: show when the increment rippled to OTHER boards.
        const otherBoards = affectedBoards.filter((b) => b.boardId !== boardId);
        if (otherBoards.length > 0) {
          const counterName = resolveCreditedCounterName(taskMap[sourceTaskId]);
          onCreditedToast({
            sourceTaskId,
            counterName,
            amount,
            verb: 'logged',
            boardNames: otherBoards.map((b) => b.boardName),
            key: Date.now(),
          });
        }
      } catch (err) {
        console.error('Shared counter increment failed:', err);
        onFlash('Something went wrong', 'bingo');
      }
    },
    [boardId, playLocked, onFlash, onCreditedToast, taskMap],
  );

  /**
   * Phase 2 — Shared Counters: decrement the shared-counter accumulator for a
   * given source task id. Mirrors handleSharedCounterIncrement; the engine
   * clamps to 0 internally so this is always safe to call.
   *
   * R3 — amount-aware: `amount` (default 1) is the amount requested; the
   * toast (and `persistAsDefault`, when set) uses `effectiveDelta` — the
   * actually-removed amount after the engine's clamp-at-0 — so the toast's
   * displayed delta always matches what `undoLastCounterLog` will reverse.
   *
   * @param sourceTaskId - The source task id (same rules as increment).
   * @param amount - Units requested to remove (default 1).
   * @param persistAsDefault - Persist `amount` as the new default (default false).
   */
  const handleSharedCounterDecrement = useCallback(
    async (sourceTaskId: string, amount = 1, persistAsDefault = false): Promise<void> => {
      if (playLocked) return;
      try {
        // Capture the pre-decrement board stats for the board-transition flash.
        const boardBefore = await db.boards.get(boardId);
        const { affectedBoards, effectiveDelta } = await decrementSharedCounter(sourceTaskId, amount, boardId);
        // No-op: nothing changed (count was already 0).
        if (effectiveDelta === 0) return;
        if (persistAsDefault) {
          await setCounterDefaultLogAmount(sourceTaskId, amount);
        }

        // Board-transition flash (F1): decrementing a completed square can drop
        // it below its goal on this window and flip the board COMPLETED→ACTIVE,
        // dropping bingo lines. The increment path already flashes the mirror
        // ACTIVE→COMPLETED case; without this the decrement silently reactivated
        // the board with no feedback. Same before/after snapshot diff as
        // handleSharedCounterIncrement, but only the reactivated / lost-bingo
        // rungs can fire on a decrement (never greenlog / new bingos).
        const boardAfter = await db.boards.get(boardId);
        if (boardBefore && boardAfter) {
          const prevBingos = new Set(boardBefore.completedLineIds ?? []);
          const nextBingos = new Set(boardAfter.completedLineIds ?? []);
          const lostBingos = [...prevBingos].filter((id) => !nextBingos.has(id));
          const wasCompleted = boardBefore.status === BoardStatus.COMPLETED;
          const isNowActive = boardAfter.status === BoardStatus.ACTIVE;
          const outcome = deriveFlashOutcome({
            boardReactivated: wasCompleted && isNowActive,
            lostBingos,
            isGreenlog: false,
            newBingos: [],
          });
          if (outcome) onFlash(outcome.text, outcome.variant);
        }

        // Credited toast: show when the decrement rippled to OTHER boards.
        const otherBoards = affectedBoards.filter((b) => b.boardId !== boardId);
        if (otherBoards.length > 0) {
          const counterName = resolveCreditedCounterName(taskMap[sourceTaskId]);
          onCreditedToast({
            sourceTaskId,
            counterName,
            amount: effectiveDelta,
            verb: 'removed',
            boardNames: otherBoards.map((b) => b.boardName),
            key: Date.now(),
          });
        }
      } catch (err) {
        console.error('Shared counter decrement failed:', err);
        onFlash('Something went wrong', 'bingo');
      }
    },
    [boardId, playLocked, onFlash, onCreditedToast, taskMap],
  );

  /**
   * R3 — Undo the last shared-counter log for a source task (the credited
   * toast's Undo pill routes here). Reversing a log runs the same board
   * derivation cascade as a decrement, so it can drop a completed square below
   * its goal on this window and flip the board COMPLETED→ACTIVE, dropping bingo
   * lines (F1). Mirror handleSharedCounterDecrement's before/after snapshot diff
   * so the reversal surfaces the same "Board reactivated / Bingo lost" flash a
   * manual decrement does — previously the Undo pill was silent about it.
   *
   * Exceptions propagate to the caller (BoardPlaySurface's toast handler), which
   * owns the error log + credited-toast dismissal.
   */
  const undoCounterLog = useCallback(
    async (sourceTaskId: string): Promise<void> => {
      // Capture the pre-undo board stats for the board-transition flash.
      const boardBefore = await db.boards.get(boardId);
      const { undoneAmount } = await undoLastCounterLog(sourceTaskId);
      // No-op: nothing was reversed (no undoable entry) → no state change.
      if (undoneAmount === 0) return;
      const boardAfter = await db.boards.get(boardId);
      if (!boardBefore || !boardAfter) return;

      const prevBingos = new Set(boardBefore.completedLineIds ?? []);
      const nextBingos = new Set(boardAfter.completedLineIds ?? []);
      const lostBingos = [...prevBingos].filter((id) => !nextBingos.has(id));
      const wasCompleted = boardBefore.status === BoardStatus.COMPLETED;
      const isNowActive = boardAfter.status === BoardStatus.ACTIVE;
      const outcome = deriveFlashOutcome({
        boardReactivated: wasCompleted && isNowActive,
        lostBingos,
        isGreenlog: false,
        newBingos: [],
      });
      if (outcome) onFlash(outcome.text, outcome.variant);
    },
    [boardId, onFlash],
  );

  const undoCreditedToast = useCallback(
    async (toast: CreditedToast): Promise<void> => {
      if (toast.undo?.kind === 'uncomplete') {
        // A counts-toward credit is derived: putting the square back tombstones it (never `undoLastCounterLog`).
        await handleComplete(toast.undo.boardTaskId, toast.undo.updates);
        return;
      }
      await undoCounterLog(toast.sourceTaskId);
    },
    [handleComplete, undoCounterLog],
  );

  /**
   * Handles toggling a compound child task from the detail sheet.
   *
   * Only a placement on the CURRENT board can go through `handleComplete`, whose
   * orchestration (`handleTaskCompletion`) hard-guards `targetBt.boardId ===
   * boardId` and throws otherwise. A child placed only on ANOTHER board — or not
   * placed at all — routes through `toggleCompoundChildFallback`, which writes
   * against THIS board's window + re-runs the cross-board cascade so the parent
   * compound (on this board) re-derives its completion + the board stats.
   * Either way the direction is the inverse of the WINDOWED state the sheet
   * paints (`compoundChildToggleDesired`), never the lifetime latch — on an
   * ended board a later window's completion sets the latch but not this sheet.
   *
   * (F2 — web↔iOS parity: iOS already falls through to the board-agnostic
   * cascade for an other-board child; previously web misrouted the other-board
   * BoardTask into `handleComplete` and threw "Something went wrong".)
   */
  const handleCompoundChildToggle = useCallback(
    async (childTaskId: string): Promise<void> => {
      if (playLocked) return;
      const childTask = taskMap[childTaskId];
      if (!childTask) return;

      // Only the CURRENT-board placement is eligible for handleComplete.
      const currentBt = boardTasks.find((bt) => bt.taskId === childTaskId);
      const desired =
        compoundChildToggleDesired(childTask, taskMap, compoundChildrenByCompound, squareWindowContext);

      if (currentBt) {
        await handleComplete(currentBt.id, { isCompleted: desired });
      } else {
        // Child is not on the current board (placed elsewhere, or not at all),
        // but the parent compound still derives through it. One Dexie
        // transaction (event write + sync enqueue + cascade), so a downstream
        // failure rolls back the partial writes (issue #270, B2-W2).
        try {
          const { windowStart, windowEnd } = squareWindowContext;
          await toggleCompoundChildFallback(childTaskId, desired, windowStart, windowEnd, boardId);
        } catch (err) {
          console.error('Compound child toggle failed:', err);
          onFlash('Something went wrong', 'bingo');
        }
      }
    },
    [playLocked, taskMap, boardTasks, handleComplete, onFlash, boardId,
      compoundChildrenByCompound, squareWindowContext]
  );

  return {
    editDraft,
    commitEdits,
    handleComplete,
    handleSharedCounterIncrement,
    handleSharedCounterDecrement,
    undoCounterLog,
    undoCreditedToast,
    handleCompoundChildToggle,
  };
}
