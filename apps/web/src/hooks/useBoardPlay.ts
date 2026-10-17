import { useCallback, useRef, useState } from 'react';
import {
  TaskType,
  counterDisplayName,
  effectiveCenter,
  quantizeCount,
  resolveCountKind,
  resolveTaskWindowState,
  type CountKind,
  type Board,
  type BoardSize,
  type BoardTask,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { db } from '../db/internal';
import { compoundChildToggleDesired, type SquareWindowContext } from '../db/adapters';
import { handleTaskCompletion } from '../db/operations/orchestration';
import { findNewBoardCredit, snapshotLiveCreditIds, type NewBoardCredit } from '../db/operations/countsTowardSection';
import {
  decrementSharedCounter,
  incrementSharedCounter,
  setCounterDefaultLogAmount,
} from '../db/operations/tasks';
import { resolveCreditedCounterName, resolveSharedCounterSourceId } from '../components/boardPlaySharedCounterUtils';
import { deriveFlashOutcome, flashFromBoardSnapshots, messageOutcome, type FlashOutcome } from '../components/boardPlayFlash';
import { incrementCompoundChildFallback, toggleCompoundChildFallback, undoLastCounterLog } from '../db/operations/tasks';
import { commitSquareEdits } from '../db/operations/boardEditCommit';
import type { ContextMenuState } from '../components/interactiveTaskSquareUtils';
import { useSquaresEditDraft, type UseSquaresEditDraftResult } from './useSquaresEditDraft';

/** The flagged tasks placed on this board, in board order (the credited toast's contributors). */
export function onBoardContributors(boardTasks: ReadonlyArray<BoardTask>, taskMap: Record<string, Task>): Task[] {
  const seen = new Set<string>();
  const out: Task[] = [];
  for (const bt of boardTasks) {
    const t = taskMap[bt.taskId];
    if (!t || seen.has(t.id) || t.countsTowardCounterId == null || t.sharedCounterId != null) continue;
    seen.add(t.id);
    out.push(t);
  }
  return out;
}

/**
 * The write that puts a square back after a completion write — the credited
 * toast's Undo (design handoff §C4): a Simple square is un-completed, a
 * Counting square is restored to its PREVIOUS windowed count (read from the
 * pre-write window snapshot), anything else is left to the caller.
 */
export function revertUpdatesFor(
  task: Task,
  updates: { isCompleted?: boolean; currentCount?: number },
  ctx: SquareWindowContext,
): { isCompleted?: boolean; currentCount?: number } | null {
  if (updates.isCompleted !== undefined) return { isCompleted: !updates.isCompleted };
  if (updates.currentCount !== undefined) {
    const before = resolveTaskWindowState(task, ctx.eventsByTaskId[task.id] ?? [], ctx.windowStart, ctx.windowEnd);
    return { currentCount: before.count };
  }
  return null;
}

/**
 * The task a write touched plus every compound that derives through it,
 * transitively (`childrenByCompound` inverted) — the only tasks a credit from
 * that write can belong to. Attributing to these alone keeps a credit that
 * lands between the two snapshots (a pull, a rapid second tap on another
 * square) from being pinned on — and undone through — the wrong square.
 */
export function writtenLineage(taskId: string, childrenByCompound: Record<string, CompoundChild[]>): Set<string> {
  const out = new Set<string>([taskId]);
  const stack = [taskId];
  while (stack.length > 0) {
    const child = stack.pop() as string;
    for (const [compoundId, links] of Object.entries(childrenByCompound)) {
      if (out.has(compoundId) || !links.some((l) => !l.isDeleted && l.childTaskId === child)) continue;
      out.add(compoundId);
      stack.push(compoundId);
    }
  }
  return out;
}

/** The credited toast for the counts-toward credits this write produced (its Undo reverses the write). */
function countsTowardCreditToast(found: NewBoardCredit, revert: () => Promise<void>): CreditedToast {
  return {
    sourceTaskId: found.root.id,
    counterName: counterDisplayName(found.root),
    amount: found.amount,
    kind: resolveCountKind(found.root),
    verb: 'logged',
    boardNames: found.otherBoards.map((b) => b.boardName),
    key: Date.now(),
    undo: { kind: 'uncomplete', revert },
  };
}

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
  undo?: { kind: 'counterLog' } | { kind: 'uncomplete'; revert: () => Promise<void> };
  /** Pair-derived counter name (`resolveCreditedCounterName`), never raw `task.title`. */
  counterName: string;
  /** The amount actually applied (for a decrement, the clamped `effectiveDelta`) — matches what Undo will reverse. */
  amount: number;
  verb: 'logged' | 'removed';
  boardNames: string[];
  key: number;
  /** The credited counter's kind (formats the amount). */
  kind?: CountKind;
  /** A tap-contract toast (docs/TASK_DETAIL_REDESIGN.md): replaces the counter copy with this line. */
  text?: string;
  /** Second, muted line under `text` (the board, plus " · +1 ‹counter›" on a credit). */
  detail?: string;
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
  /** Counter ROOT ids on this board's task set (`useBoardPlayData`) — a root
   *  child of a compound steps on its own counter, like a placed root square. */
  sharedCounterSourceIds: Set<string>;
  /** Show a transient flash / the bingo or greenlog moment (component's `showFlash`). */
  onFlash: (outcome: FlashOutcome) => void;
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
  /** @returns true when the write committed (false: locked, or a caught failure). */
  handleComplete: (
    boardTaskId: string,
    updates: { isCompleted?: boolean; currentCount?: number; completedStepIds?: string[] },
  ) => Promise<boolean>;
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
  ) => Promise<number>;
  /** Mirrors `handleSharedCounterIncrement` — see its param docs. */
  handleSharedCounterDecrement: (
    sourceTaskId: string,
    amount?: number,
    persistAsDefault?: boolean,
  ) => Promise<number>;
  /**
   * Reverse the most recent shared-counter log for a source task (the
   * credited-toast Undo pill), flashing any board COMPLETED→ACTIVE / lost-bingo
   * transition the reversal causes (F1 — mirrors `handleSharedCounterDecrement`).
   * May throw (invalid source); the caller owns the toast-dismiss + error path.
   */
  undoCounterLog: (sourceTaskId: string) => Promise<void>;
  /** The credited toast's Undo: reverses a hand log, or un-completes a counts-toward contributor. */
  undoCreditedToast: (toast: CreditedToast) => Promise<void>;
  /**
   * Toggles a compound child; `to` forces the target state (an Undo's explicit
   * revert). @returns the state written, or null when nothing was committed.
   */
  handleCompoundChildToggle: (childTaskId: string, to?: boolean) => Promise<boolean | null>;
  /**
   * The compound sheet's stepper on a COUNTING child: `+1` logs the child's
   * step, `-1` removes it. A linked child logs on its counter (the same path
   * as a placed linked square); a plain child placed here goes through the
   * orchestration, else `incrementCompoundChildFallback` (this board's window).
   * `amount` (a tap-to-log chip) overrides the ±1 / counter-default step.
   */
  handleCompoundChildIncrement: (childTaskId: string, direction: 1 | -1, amount?: number) => Promise<number>;
  /**
   * Adds a signed delta to a standalone counting square, reading the prior
   * count inside the write. @returns the prior count + amount applied, or null
   * when nothing was committed (locked, dropped while busy, clamped to no-op, failure).
   */
  logStandaloneCount: (boardTaskId: string, delta: number) => Promise<{ before: number; applied: number } | null>;
  /** Bumped whenever a write settles; an Undo strip from an earlier value is stale. */
  writeSeq: number;
  /** The live write sequence (read after an await, where `writeSeq` would be stale). */
  getWriteSeq: () => number;
  /** A play-mode write or undo is in flight — the sheet disables (never hides) its controls. */
  isWriting: boolean;
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
    sharedCounterSourceIds,
    onFlash,
    onCreditedToast,
    setContextMenu,
  } = params;
  const boardId = board.id;

  // Busy flag: counts writes in flight (an undo is a write too). `inFlight` is
  // the synchronous twin the compound-step re-entrancy guard reads.
  const inFlight = useRef(0);
  const seqRef = useRef(0);
  const [isWriting, setIsWriting] = useState(false);
  // Bumped when a write settles: an Undo strip made before it is stale.
  const [writeSeq, setWriteSeq] = useState(0);
  const getWriteSeq = useCallback(() => seqRef.current, []);
  const track = useCallback(async <T,>(fn: () => Promise<T>): Promise<T> => {
    inFlight.current += 1;
    setIsWriting(true);
    try {
      return await fn();
    } finally {
      inFlight.current -= 1;
      seqRef.current += 1;
      setWriteSeq(seqRef.current);
      if (inFlight.current === 0) setIsWriting(false);
    }
  }, []);

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
  const completeRaw = useCallback(
    async (
      boardTaskId: string,
      updates: {
        isCompleted?: boolean;
        currentCount?: number;
        completedStepIds?: string[];
      }
    ): Promise<boolean> => {
      if (!boardId) return false;
      try {
        const result = await handleTaskCompletion(boardId, boardTaskId, updates);
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
        if (outcome) onFlash(outcome);
        return true;
      } catch (err) {
        console.error('Task completion failed:', err);
        onFlash(messageOutcome('Something went wrong'));
        setContextMenu(null);
        return false;
      }
    },

    [boardId, onFlash, setContextMenu]
  );

  /**
   * "Counts toward" (design handoff §C4, ruled 2026-10-10): runs `write`
   * between two looks at the live credits on the roots of the flagged tasks
   * placed on this board; a NEW live credit that belongs to one of them (the
   * cascade actually credited this board's contributor) shows the credited
   * toast — only when the counter has squares on OTHER boards whose window
   * contains the credit. Nothing credited (a late log before `since`, a
   * seal-suppressed write, a lineage already credited, an unflagged task) →
   * no toast. `revert` is the toast's Undo: the exact inverse write.
   */
  const watchCredits = useCallback(
    async (writtenTaskId: string, write: () => Promise<boolean>, revert: () => Promise<unknown>): Promise<boolean> => {
      const lineage = writtenLineage(writtenTaskId, compoundChildrenByCompound);
      const contributors = onBoardContributors(boardTasks, taskMap).filter((c) => lineage.has(c.id));
      if (!boardId || contributors.length === 0) return write();
      const roots = [...new Set(contributors.map((c) => c.countsTowardCounterId as string))];
      const before = await snapshotLiveCreditIds(roots);
      const committed = await write();
      if (!committed) return false;
      const found = await findNewBoardCredit(boardId, contributors, before);
      if (found && found.otherBoards.length > 0) onCreditedToast(countsTowardCreditToast(found, async () => { await revert(); }));
      return true;
    },
    [boardId, boardTasks, taskMap, compoundChildrenByCompound, onCreditedToast],
  );

  /** {@link completeRaw} under the credited-toast watch (the Undo puts the square back). */
  const handleCompleteRaw = useCallback(
    async (boardTaskId: string, updates: { isCompleted?: boolean; currentCount?: number; completedStepIds?: string[] }): Promise<boolean> => {
      const bt = boardTasks.find((b) => b.id === boardTaskId);
      const task = bt ? taskMap[bt.taskId] : undefined;
      const revert = task ? revertUpdatesFor(task, updates, squareWindowContext) : null;
      if (!task) return completeRaw(boardTaskId, updates);
      return watchCredits(
        task.id,
        () => completeRaw(boardTaskId, updates),
        () => (revert ? completeRaw(boardTaskId, revert) : Promise.resolve()),
      );
    },
    [boardTasks, taskMap, squareWindowContext, watchCredits, completeRaw],
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
  const incrementRaw = useCallback(
    async (sourceTaskId: string, amount = 1, persistAsDefault = false): Promise<number> => {
      if (playLocked) return 0;
      try {
        // Capture the pre-increment board stats for flash comparison.
        const boardBefore = await db.boards.get(boardId);
        const { affectedBoards } = await incrementSharedCounter(sourceTaskId, amount, boardId);
        if (persistAsDefault) {
          await setCounterDefaultLogAmount(sourceTaskId, amount);
        }
        // Re-fetch to get post-increment board state.
        const boardAfter = await db.boards.get(boardId);
        if (!boardBefore || !boardAfter) return amount;

        // Same shared ladder as handleComplete, fed from a before/after
        // snapshot diff — see boardPlayFlash.ts for why the derivations differ.
        const outcome = flashFromBoardSnapshots(boardBefore, boardAfter, true);
        if (outcome) onFlash(outcome);

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
        return amount;
      } catch (err) {
        console.error('Shared counter increment failed:', err);
        onFlash(messageOutcome('Something went wrong'));
        return 0;
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
  const decrementRaw = useCallback(
    async (sourceTaskId: string, amount = 1, persistAsDefault = false): Promise<number> => {
      if (playLocked) return 0;
      try {
        // Capture the pre-decrement board stats for the board-transition flash.
        const boardBefore = await db.boards.get(boardId);
        const { affectedBoards, effectiveDelta } = await decrementSharedCounter(sourceTaskId, amount, boardId);
        // No-op: nothing changed (count was already 0).
        if (effectiveDelta === 0) return 0;
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
          const outcome = flashFromBoardSnapshots(boardBefore, boardAfter, false);
          if (outcome) onFlash(outcome);
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
        return effectiveDelta;
      } catch (err) {
        console.error('Shared counter decrement failed:', err);
        onFlash(messageOutcome('Something went wrong'));
        return 0;
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
  const undoCounterLogRaw = useCallback(
    async (sourceTaskId: string): Promise<void> => {
      // Capture the pre-undo board stats for the board-transition flash.
      const boardBefore = await db.boards.get(boardId);
      const { undoneAmount } = await undoLastCounterLog(sourceTaskId);
      // No-op: nothing was reversed (no undoable entry) → no state change.
      if (undoneAmount === 0) return;
      const boardAfter = await db.boards.get(boardId);
      if (!boardBefore || !boardAfter) return;

      const outcome = flashFromBoardSnapshots(boardBefore, boardAfter, false);
      if (outcome) onFlash(outcome);
    },
    [boardId, onFlash],
  );

  const undoCreditedToastRaw = useCallback(
    async (toast: CreditedToast): Promise<void> => {
      if (toast.undo?.kind === 'uncomplete') {
        // A counts-toward credit is derived: putting the square back tombstones it (never `undoLastCounterLog`).
        await toast.undo.revert();
        return;
      }
      await undoCounterLogRaw(toast.sourceTaskId);
    },
    [undoCounterLogRaw],
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
  const toggleChildRaw = useCallback(
    async (childTaskId: string, explicit?: boolean): Promise<boolean | null> => {
      if (playLocked) return null;
      const childTask = taskMap[childTaskId];
      if (!childTask) return null;

      // Only the CURRENT-board placement is eligible for handleComplete.
      const currentBt = boardTasks.find((bt) => bt.taskId === childTaskId);
      const desired =
        explicit ?? compoundChildToggleDesired(childTask, taskMap, compoundChildrenByCompound, squareWindowContext);

      const toggle = async (to: boolean): Promise<boolean> => {
        if (currentBt) return completeRaw(currentBt.id, { isCompleted: to });
        // Child is not on the current board (placed elsewhere, or not at all),
        // but the parent compound still derives through it. One Dexie
        // transaction (event write + sync enqueue + cascade), so a downstream
        // failure rolls back the partial writes (issue #270, B2-W2).
        try {
          const { windowStart, windowEnd } = squareWindowContext;
          const boardBefore = await db.boards.get(boardId);
          await toggleCompoundChildFallback(childTaskId, to, windowStart, windowEnd, boardId);
          const boardAfter = await db.boards.get(boardId);
          const outcome = boardBefore && boardAfter ? flashFromBoardSnapshots(boardBefore, boardAfter, true) : null;
          if (outcome) onFlash(outcome);
          return true;
        } catch (err) {
          console.error('Compound child toggle failed:', err);
          onFlash(messageOutcome('Something went wrong'));
          return false;
        }
      };
      // A flagged compound completed by this toggle credits its counter once
      // (the watch); the toast's Undo toggles the child back.
      const committed = await watchCredits(childTaskId, () => toggle(desired), () => toggle(!desired));
      return committed ? desired : null;
    },
    [playLocked, taskMap, boardTasks, completeRaw, watchCredits, onFlash, boardId,
      compoundChildrenByCompound, squareWindowContext]
  );

  /**
   * The windowed count of `task` read FRESH from the events table, never from
   * render state — a delta write computed from a stale render would lose a
   * log made a moment earlier (the absolute-count race).
   */
  const freshCount = useCallback(
    async (task: Task): Promise<number> => {
      const events = (await db.taskEvents.where('taskId').equals(task.id).toArray()).filter((e) => !e.isDeleted);
      const { windowStart, windowEnd } = squareWindowContext;
      return resolveTaskWindowState(task, events, windowStart, windowEnd).count;
    },
    [squareWindowContext],
  );

  /**
   * Adds a signed `delta` to a STANDALONE counting square: the prior count is
   * read inside the write and the absolute target derived from it, so `before`
   * (what an Undo restores) is the true prior value.
   *
   * @returns the prior count and the amount actually applied (clamped at 0),
   *   or null when nothing was committed.
   */
  const logStandaloneRaw = useCallback(
    async (boardTaskId: string, delta: number): Promise<{ before: number; applied: number } | null> => {
      if (playLocked) return null;
      const bt = boardTasks.find((b) => b.id === boardTaskId);
      const task = bt ? taskMap[bt.taskId] : undefined;
      if (!task) return null;
      const before = await freshCount(task);
      const next = Math.max(0, quantizeCount(before + delta));
      const applied = Math.abs(quantizeCount(next - before));
      if (applied === 0) return null;
      const committed = await handleCompleteRaw(boardTaskId, { currentCount: next });
      return committed ? { before, applied } : null;
    },
    [playLocked, boardTasks, taskMap, freshCount, handleCompleteRaw],
  );

  /**
   * Counting children can't be tap-toggled (a completion event means nothing
   * to a count, and a linked child's count is its counter's), so the sheet
   * steps them. Same routing as `handleCompoundChildToggle`: a placement on
   * THIS board goes through the orchestration; otherwise the board-window
   * fallback. A linked child always logs on its counter, by the counter's
   * default amount, exactly like a placed linked square.
   *
   * @returns the amount actually applied; 0 when nothing was committed.
   */
  const stepChildRaw = useCallback(
    async (childTaskId: string, direction: 1 | -1, amount?: number): Promise<number> => {
      if (playLocked) return 0;
      const childTask = taskMap[childTaskId];
      if (!childTask || childTask.type !== TaskType.COUNTING) return 0;
      // A linked child — or a counter ROOT child — steps on its counter.
      const sourceId = resolveSharedCounterSourceId(childTask, sharedCounterSourceIds);
      if (sourceId) {
        const step = amount ?? taskMap[sourceId]?.defaultLogAmount ?? 1;
        return direction > 0 ? incrementRaw(sourceId, step) : decrementRaw(sourceId, step);
      }
      const { windowStart, windowEnd } = squareWindowContext;
      const current = await freshCount(childTask);
      const step = amount ?? 1;
      const delta = direction > 0 ? step : -Math.min(step, current);
      if (delta === 0) return 0;
      const currentBt = boardTasks.find((bt) => bt.taskId === childTaskId);
      const apply = async (next: number, d: number): Promise<boolean> => {
        if (currentBt) return completeRaw(currentBt.id, { currentCount: next });
        try {
          const boardBefore = await db.boards.get(boardId);
          await incrementCompoundChildFallback(childTaskId, d, windowStart, windowEnd, boardId);
          const boardAfter = await db.boards.get(boardId);
          const outcome = boardBefore && boardAfter ? flashFromBoardSnapshots(boardBefore, boardAfter, d > 0) : null;
          if (outcome) onFlash(outcome);
          return true;
        } catch (err) {
          console.error('Compound child increment failed:', err);
          onFlash(messageOutcome('Something went wrong'));
          return false;
        }
      };
      // A flagged compound completed by this step credits its counter once
      // (the watch); the toast's Undo steps the child back.
      const committed = await watchCredits(childTaskId, () => apply(quantizeCount(current + delta), delta), () => apply(current, -delta));
      return committed ? Math.abs(delta) : 0;
    },
    [playLocked, taskMap, boardTasks, completeRaw, watchCredits, onFlash, boardId, squareWindowContext,
      sharedCounterSourceIds, incrementRaw, decrementRaw, freshCount]
  );

  // Every exported write runs under the busy flag (the sheet disables, never
  // hides, its controls while it is set). The two absolute-count writes also
  // DROP when another write is in flight (they read-then-write the count).
  const handleComplete = useCallback((...a: Parameters<typeof handleCompleteRaw>) => track(() => handleCompleteRaw(...a)), [track, handleCompleteRaw]);
  const handleSharedCounterIncrement = useCallback((...a: Parameters<typeof incrementRaw>) => track(() => incrementRaw(...a)), [track, incrementRaw]);
  const handleSharedCounterDecrement = useCallback((...a: Parameters<typeof decrementRaw>) => track(() => decrementRaw(...a)), [track, decrementRaw]);
  const undoCounterLog = useCallback((id: string) => track(() => undoCounterLogRaw(id)), [track, undoCounterLogRaw]);
  const undoCreditedToast = useCallback((t: CreditedToast) => track(() => undoCreditedToastRaw(t)), [track, undoCreditedToastRaw]);
  const handleCompoundChildToggle = useCallback((id: string, to?: boolean) => track(() => toggleChildRaw(id, to)), [track, toggleChildRaw]);
  const logStandaloneCount = useCallback(
    (id: string, delta: number) => (inFlight.current > 0 ? Promise.resolve(null) : track(() => logStandaloneRaw(id, delta))),
    [track, logStandaloneRaw],
  );
  const handleCompoundChildIncrement = useCallback(
    (id: string, direction: 1 | -1, amount?: number) => (inFlight.current > 0 ? Promise.resolve(0) : track(() => stepChildRaw(id, direction, amount))),
    [track, stepChildRaw],
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
    handleCompoundChildIncrement,
    logStandaloneCount,
    isWriting,
    writeSeq,
    getWriteSeq,
  };
}
