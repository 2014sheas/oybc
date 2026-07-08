import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  generateCounterTaskTitle,
  type Board,
  type BoardSize,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskStep,
} from '@oybc/shared';
import { db } from '../db/database';
import { taskToSquareData, taskToSquareState } from '../db/adapters';
import { handleTaskCompletion } from '../db/operations/orchestration';
import { decrementSharedCounter, incrementSharedCounter } from '../db/operations/tasks';
import {
  updateBoardTaskAndCascade,
  removeBoardTaskFromBoard,
  addBoardTaskToBoard,
  reorderBoardTasks,
} from '../db/operations/boardTasks';
import { updateTaskAndCascade, toggleTaskCompletionAndCascade, type UpdateTaskPatch } from '../db/operations/tasks';
import { deriveFlashOutcome } from '../components/boardPlayFlash';
import type { ContextMenuState } from '../components/interactiveTaskSquareUtils';
import { type SubMode } from '../components/boardEdit/BoardEditPanel';
import { type ArrangeSlot } from '../components/boardEdit/ArrangeGrid';
import { type BoardCellModel } from '../components/board/RisoBoardCell';

// Module-scoped frozen empty array. Reused as a stable fallback so React
// Compiler can preserve memoization of downstream useCallback/useMemo deps;
// an inline `?? []` re-allocates on every render and trips
// `react-hooks/preserve-manual-memoization`. Typed as the mutable element
// array because consumers (legacy step helpers) require `T[]`, not
// `readonly T[]`; the runtime frozen array still throws on mutation.
const EMPTY_TASK_STEPS = Object.freeze([]) as unknown as TaskStep[];

/**
 * Per-cell staged entry for the squares draft (Phase 2 — staged edit model).
 * Seeded from live `BoardTask` rows on entering edit mode; mutated only by
 * Replace/Edit actions — never by live-query updates (to avoid clobbering
 * staged changes mid-session).
 */
export interface SquareDraftCell {
  boardTaskId: string;
  /** Current staged row — may differ from originalRow after a Rearrange. */
  row: number;
  /** Current staged col — may differ from originalCol after a Rearrange. */
  col: number;
  isCenter: boolean;
  /** Current staged taskId — may differ from originalTaskId after a Replace. */
  taskId: string;
  /** The taskId at the time edit mode was entered. Never changes. */
  originalTaskId: string;
  /** The row at the time edit mode was entered. Never changes (Phase 3). */
  originalRow: number;
  /** The col at the time edit mode was entered. Never changes (Phase 3). */
  originalCol: number;
}

/** What `onFlash` is called with. `greenlog` routes to the overlay and a
 *  new bingo to the toast; only the residual cases reach the transient flash. */
export type FlashVariant = 'bingo' | 'greenlog';

/** Credited-toast payload shown after a shared-counter ripple to OTHER boards. */
export interface CreditedToast {
  name: string;
  delta: number;
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
  allBoardTasks: BoardTask[];
  gridSize: BoardSize;
  isExpired: boolean;
  /** Show a transient flash / bingo toast / greenlog overlay (component's `showFlash`). */
  onFlash: (text: string, variant: FlashVariant) => void;
  /** Show the shared-counter credited toast (component's `setCreditedToast`). */
  onCreditedToast: (toast: CreditedToast) => void;
  /** Dismiss the floating context menu (component's `setContextMenu`). */
  setContextMenu: React.Dispatch<React.SetStateAction<ContextMenuState | null>>;
}

/** Everything `BoardPlaySurface` needs from the handler/edit-draft layer. */
export interface UseBoardPlayResult {
  // ── Edit-draft state ──
  squaresDraft: SquareDraftCell[];
  taskOverrides: Map<string, UpdateTaskPatch>;
  draftCenterType: CenterSquareType;
  setDraftCenterType: React.Dispatch<React.SetStateAction<CenterSquareType>>;
  subMode: SubMode;
  setSubMode: React.Dispatch<React.SetStateAction<SubMode>>;
  squareTapMenu: {
    boardTaskId: string;
    taskId: string;
    x: number;
    y: number;
    isCenterTask: boolean;
  } | null;
  setSquareTapMenu: React.Dispatch<
    React.SetStateAction<{
      boardTaskId: string;
      taskId: string;
      x: number;
      y: number;
      isCenterTask: boolean;
    } | null>
  >;
  freeCenterTapMenu: { x: number; y: number } | null;
  setFreeCenterTapMenu: React.Dispatch<React.SetStateAction<{ x: number; y: number } | null>>;
  editReplaceId: string | null;
  setEditReplaceId: React.Dispatch<React.SetStateAction<string | null>>;
  editTaskSheetId: string | null;
  setEditTaskSheetId: React.Dispatch<React.SetStateAction<string | null>>;
  // ── Derived edit-mode data ──
  squareEditCount: number;
  draftByPosition: Record<string, SquareDraftCell>;
  arrangeSlots: ArrangeSlot[];
  // ── Draft handlers ──
  handleEditReplace: (boardTaskId: string, newTaskId: string) => void;
  handleEditTaskDone: (taskId: string, patch: UpdateTaskPatch) => void;
  handleRearrangeReorder: (newSlots: ArrangeSlot[]) => void;
  commitSquareEdits: () => Promise<void>;
  // ── Completion handlers ──
  handleComplete: (
    boardTaskId: string,
    updates: { isCompleted?: boolean; currentCount?: number; completedStepIds?: string[] },
  ) => Promise<void>;
  handleSharedCounterIncrement: (sourceTaskId: string) => Promise<void>;
  handleSharedCounterDecrement: (sourceTaskId: string) => Promise<void>;
  handleCompoundChildToggle: (childTaskId: string) => Promise<void>;
  // ── Board-task write methods (from the play-mode swap/remove/add modals) ──
  swapBoardTask: (boardTaskId: string, newTaskId: string) => Promise<void>;
  removeBoardTask: (boardTaskId: string) => Promise<void>;
  addTaskToCell: (taskId: string, row: number, col: number) => Promise<void>;
}

/**
 * The handler + edit-draft logic layer for playing a board. Extracted from
 * `BoardPlaySurface` (B2-W3, issue #270) — pure code-motion, no behavior
 * change. Owns the staged edit-mode draft (squares / overrides / center /
 * sub-mode / tap menus / replace + task-edit sheets), the completion
 * orchestration handlers, and the play-mode board-task write methods; the
 * component keeps the flash/toast/timer UI and all JSX.
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
    allBoardTasks,
    gridSize,
    isExpired,
    onFlash,
    onCreditedToast,
    setContextMenu,
  } = params;
  const boardId = board.id;

  // ── Phase 2 — Edit tasks sub-mode + squares draft ────────────────────────

  // Sub-mode is hoisted here (from BoardEditPanel) so the grid can gate taps.
  const [subMode, setSubMode] = useState<SubMode>('editTasks');

  // Squares draft: per-cell staged state seeded when entering edit mode.
  // Never updated by live boardTasks changes (only by Replace/Edit actions).
  const [squaresDraft, setSquaresDraft] = useState<SquareDraftCell[]>([]);

  // Staged task-field overrides, keyed by taskId.
  // Applied to the grid display while in edit mode; committed on Save.
  const [taskOverrides, setTaskOverrides] = useState<Map<string, UpdateTaskPatch>>(
    () => new Map(),
  );

  // Phase 2b — draft centerSquareType, lifted so the grid can compute
  // isPinnedCenter. Seeded on edit-mode entry from board.centerSquareType;
  // updated by both the BoardSetupForm selector (via BoardEditPanel) and the
  // center cell toggle (direct tap in editTasks mode).
  const [draftCenterType, setDraftCenterType] = useState<CenterSquareType>(
    board.centerSquareType as CenterSquareType,
  );

  // Phase 2b — tap menu for the FREE/CUSTOM_FREE center in editTasks mode.
  // The free center has no boardTaskId so it can't use squareTapMenu.
  const [freeCenterTapMenu, setFreeCenterTapMenu] = useState<{
    x: number;
    y: number;
  } | null>(null);

  // Tap menu: set when a non-pinned square is tapped in editTasks sub-mode.
  // Stores click coordinates (not a DOMRect) because RisoBoardCell's onClick
  // is `() => void` (no event parameter). The SquareTapMenu positions itself
  // from these coordinates.
  // Phase 2b: isCenterTask added — true when the tapped cell is the NONE center;
  // causes SquareTapMenu to show the "Make it a free space" toggle item.
  const [squareTapMenu, setSquareTapMenu] = useState<{
    boardTaskId: string;
    taskId: string;
    x: number;
    y: number;
    isCenterTask: boolean;
  } | null>(null);

  // The boardTaskId whose cell is being replaced in edit mode (opens CellSwapModal).
  const [editReplaceId, setEditReplaceId] = useState<string | null>(null);

  // The taskId being edited in edit mode (opens BoardEditTaskSheet).
  const [editTaskSheetId, setEditTaskSheetId] = useState<string | null>(null);

  // Count of staged square edits — DERIVED from draft state (not an action
  // counter) so reverting a cell to its original task un-counts it (no phantom
  // edits / no "Board saved" for a net-zero session). Mirrors iOS.
  // Phase 3: also counts cells whose position differs from the original
  // (drag-to-insert / tap-to-swap), so a net-zero rearrange contributes 0.
  // Phase 2b: the rearrange-move count excludes only truly pinned centers
  // (CHOSEN / FREE / CUSTOM_FREE). A NONE center is a regular movable cell.
  const squareEditCount =
    squaresDraft.filter((c) => c.taskId !== c.originalTaskId).length +
    taskOverrides.size +
    squaresDraft.filter(
      (c) =>
        !(c.isCenter && draftCenterType !== CenterSquareType.NONE) &&
        (c.row !== c.originalRow || c.col !== c.originalCol),
    ).length;

  // Seed the squares draft when entering edit mode; reset all draft state when
  // exiting. boardTasks is intentionally NOT in the dep array — we seed once
  // on entry and must not re-seed on live-query updates (that would clobber
  // staged changes mid-session). board is also not in deps for the same reason;
  // we read board.centerSquareType once at entry time (the snapshot rule).
  useEffect(() => {
    if (!editMode) {
      setSquaresDraft([]);
      setTaskOverrides(new Map());
      setSubMode('editTasks');
      setSquareTapMenu(null);
      setEditReplaceId(null);
      setEditTaskSheetId(null);
      // Phase 2b: clear center-related menus + reset the draft center type, so a
      // toggle-then-cancel-then-reedit doesn't flash a stale FREE center for one
      // frame before the entry seed runs.
      setFreeCenterTapMenu(null);
      setDraftCenterType(board.centerSquareType as CenterSquareType);
      return;
    }
    // Phase 2b: seed draft center type from the board's current stored value.
    setDraftCenterType(board.centerSquareType as CenterSquareType);
    // Seed from the current boardTasks snapshot.
    setSquaresDraft(
      boardTasks.map((bt) => ({
        boardTaskId: bt.id,
        row: bt.row,
        col: bt.col,
        isCenter: bt.isCenter ?? false,
        taskId: bt.taskId,
        originalTaskId: bt.taskId,
        // Phase 3: original positions for derived rearrange-edit count.
        originalRow: bt.row,
        originalCol: bt.col,
      })),
    );
    setTaskOverrides(new Map());
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editMode]);

  // Phase 2 — draft position lookup (edit mode only; stable key format matches btByPosition).
  const draftByPosition: Record<string, SquareDraftCell> = {};
  if (editMode) {
    for (const cell of squaresDraft) {
      draftByPosition[`${cell.row}-${cell.col}`] = cell;
    }
  }

  // ── Phase 2 — Square-edit handlers ────────────────────────────────────────

  /**
   * Stage a Replace for the given boardTaskId.
   * Called when the CellSwapModal (edit-mode flow) confirms a new task.
   * NO DB write happens here — committed in onExtraCommit at Save time.
   */
  const handleEditReplace = useCallback((boardTaskId: string, newTaskId: string) => {
    setSquaresDraft((prev) =>
      prev.map((cell) =>
        cell.boardTaskId === boardTaskId ? { ...cell, taskId: newTaskId } : cell,
      ),
    );
    // squareEditCount is derived from squaresDraft — no manual increment.
  }, []);

  /**
   * Stage Task-field edits for the given taskId.
   * Called when BoardEditTaskSheet's Done fires.
   * Merges with any previously staged override for the same taskId.
   * NO DB write happens here — committed in onExtraCommit at Save time.
   */
  const handleEditTaskDone = useCallback(
    (taskId: string, patch: UpdateTaskPatch) => {
      setTaskOverrides((prev) => {
        const next = new Map(prev);
        const existing = next.get(taskId) ?? {};
        next.set(taskId, { ...existing, ...patch });
        return next;
      });
      // squareEditCount is derived from taskOverrides — no manual increment.
    },
    [],
  );

  /**
   * Commits all staged square edits.
   * Called by BoardEditPanel.handleSave BEFORE the metadata patch.
   * Order: task replacements first, then task-field edits.
   */
  /**
   * Phase 3 — Rearrange reorder callback.
   *
   * Called by ArrangeGrid whenever the user commits a drag-drop or tap-swap.
   * Maps the new flat slot order back to (row, col) by index position and
   * updates `squaresDraft` in place for non-center, non-empty slots.
   * The center square's position is never modified.
   */
  const handleRearrangeReorder = useCallback(
    (newSlots: ArrangeSlot[]) => {
      setSquaresDraft((prev) => {
        const newPositions = new Map<string, { row: number; col: number }>();
        newSlots.forEach((slot, i) => {
          if (!slot.isEmpty && !slot.isCenter) {
            newPositions.set(slot.cid, {
              row: Math.floor(i / gridSize),
              col: i % gridSize,
            });
          }
        });
        return prev.map((cell) => {
          const pos = newPositions.get(cell.boardTaskId);
          return pos ? { ...cell, row: pos.row, col: pos.col } : cell;
        });
      });
    },
    [gridSize],
  );

  /**
   * Phase 3 — Build the ArrangeSlot[] for rearrange sub-mode.
   *
   * Each slot carries the current staged (row, col) from squaresDraft.
   * Bingo highlights are suppressed (isLine: false) — the post-save
   * derivation pass will re-compute correct lines.
   *
   * Centre squares are flagged isCenter:true so ArrangeGrid pins them.
   * Empty positions (no draftCell at a given row/col) are flagged isEmpty:true.
   */
  const arrangeSlots = useMemo<ArrangeSlot[]>(() => {
    if (!editMode || subMode !== 'rearrange') return [];

    const half = Math.floor(gridSize / 2);

    const slots: ArrangeSlot[] = [];
    for (let r = 0; r < gridSize; r++) {
      for (let c = 0; c < gridSize; c++) {
        // Phase 2b: distinguish positional center from "pinned" center.
        // NONE center is NOT pinned — it participates in drag/swap normally.
        const isPositionalCenter = gridSize % 2 === 1 && r === half && c === half;
        const isCenter = isPositionalCenter && draftCenterType !== CenterSquareType.NONE;
        const draftCell = squaresDraft.find((d) => d.row === r && d.col === c);

        if (isPositionalCenter && !draftCell && draftCenterType !== CenterSquareType.NONE) {
          // FREE/CUSTOM_FREE (or CHOSEN with no task) centre — pinned, not draggable.
          slots.push({
            cid: `center-${r}-${c}`,
            isCenter: true,
            isEmpty: false,
            model: {
              key: `center-${r}-${c}`,
              label: 'FREE',
              type: 'normal',
              done: false,
              isFree: true,
              isLine: false,
            },
          });
        } else if (draftCell) {
          // Real tile (including CHOSEN centre).
          const baseTask: Task | undefined = taskMap[draftCell.taskId];
          let model: BoardCellModel | null = null;
          if (baseTask) {
            const task: Task =
              taskOverrides.has(draftCell.taskId)
                ? { ...baseTask, ...(taskOverrides.get(draftCell.taskId) as Partial<Task>) }
                : baseTask;
            const taskChildren = compoundChildrenByCompound[task.id] ?? [];
            const squareData = taskToSquareData(
              task, EMPTY_TASK_STEPS, taskChildren, taskMap, compoundChildrenByCompound,
            );
            const squareState = taskToSquareState(
              task, taskChildren, taskMap, compoundChildrenByCompound,
            );
            const displayLabel =
              task.title && task.title.trim()
                ? task.title
                : task.type === TaskType.COUNTING
                  ? generateCounterTaskTitle(
                      task.action ?? '',
                      task.maxCount ?? 0,
                      task.unit ?? '',
                    )
                  : '';
            model = {
              key: draftCell.boardTaskId,
              label: displayLabel,
              type:
                squareData.type === 'counting'
                  ? 'counting'
                  : squareData.type === 'compound' || squareData.type === 'progress'
                    ? 'compound'
                    : 'normal',
              done: squareState.isCompleted,
              count:
                squareData.type === 'counting'
                  ? { cur: squareState.currentCount, max: task.maxCount ?? 0 }
                  : undefined,
              isFree: false,
              isLine: false, // suppressed during rearrange
            };
          }
          slots.push({
            cid: draftCell.boardTaskId,
            isCenter,
            isEmpty: false,
            model,
          });
        } else {
          // Empty slot (no task placed here in the current draft).
          slots.push({
            cid: `empty-${r}-${c}`,
            isCenter: false,
            isEmpty: true,
            model: null,
          });
        }
      }
    }
    return slots;
  }, [
    editMode,
    subMode,
    gridSize,
    squaresDraft,
    taskMap,
    taskOverrides,
    compoundChildrenByCompound,
    draftCenterType, // Phase 2b: NONE center is not pinned
  ]);

  const commitSquareEdits = useCallback(async (): Promise<void> => {
    // 1. Cell replacements: cells whose staged taskId differs from the original.
    for (const cell of squaresDraft) {
      if (cell.taskId !== cell.originalTaskId) {
        await updateBoardTaskAndCascade(cell.boardTaskId, cell.taskId);
      }
    }
    // 2. Global task-field edits: apply UpdateTaskPatch for each staged override.
    for (const [taskId, patch] of taskOverrides.entries()) {
      await updateTaskAndCascade(taskId, patch);
    }
    // 3. Position reorders (Phase 3): cells whose staged row/col differs from original.
    //    Committed as a single atomic Dexie transaction via reorderBoardTasks.
    //    Phase 2b: NONE center is not pinned — its moves ARE included.
    const moves = squaresDraft
      .filter(
        (c) =>
          !(c.isCenter && draftCenterType !== CenterSquareType.NONE) &&
          (c.row !== c.originalRow || c.col !== c.originalCol),
      )
      .map((c) => ({ boardTaskId: c.boardTaskId, row: c.row, col: c.col }));
    if (moves.length > 0) {
      await reorderBoardTasks(boardId, moves);
    }
  }, [squaresDraft, taskOverrides, boardId, draftCenterType]);

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

    [boardId, onFlash, setContextMenu]
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
        const { affectedBoards } = await incrementSharedCounter(sourceTaskId);
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
          const sourceTask = taskMap[sourceTaskId];
          const counterName = sourceTask
            ? (sourceTask.title?.trim() ||
               generateCounterTaskTitle(sourceTask.action ?? '', sourceTask.maxCount ?? 0, sourceTask.unit ?? ''))
            : '';
          onCreditedToast({
            name: counterName,
            delta: 1,
            boardNames: otherBoards.map((b) => b.boardName),
            key: Date.now(),
          });
        }
      } catch (err) {
        console.error('Shared counter increment failed:', err);
        onFlash('Something went wrong', 'bingo');
      }
    },
    [boardId, isExpired, onFlash, onCreditedToast, taskMap],
  );

  /**
   * Phase 2 — Shared Counters: decrement the shared-counter accumulator for a
   * given source task id. Mirrors handleSharedCounterIncrement; the engine
   * clamps to 0 internally so this is always safe to call.
   *
   * @param sourceTaskId - The source task id (same rules as increment).
   */
  const handleSharedCounterDecrement = useCallback(
    async (sourceTaskId: string): Promise<void> => {
      if (isExpired) return;
      try {
        const { affectedBoards, effectiveDelta } = await decrementSharedCounter(sourceTaskId);
        // No-op: nothing changed (count was already 0).
        if (effectiveDelta === 0) return;

        // Credited toast: show when the decrement rippled to OTHER boards.
        const otherBoards = affectedBoards.filter((b) => b.boardId !== boardId);
        if (otherBoards.length > 0) {
          const sourceTask = taskMap[sourceTaskId];
          const counterName = sourceTask
            ? (sourceTask.title?.trim() ||
               generateCounterTaskTitle(sourceTask.action ?? '', sourceTask.maxCount ?? 0, sourceTask.unit ?? ''))
            : '';
          onCreditedToast({
            name: counterName,
            delta: -effectiveDelta,
            boardNames: otherBoards.map((b) => b.boardName),
            key: Date.now(),
          });
        }
      } catch (err) {
        console.error('Shared counter decrement failed:', err);
        onFlash('Something went wrong', 'bingo');
      }
    },
    [boardId, isExpired, onFlash, onCreditedToast, taskMap],
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
        // bingo state + denormalised board stats. `toggleTaskCompletionAndCascade`
        // (issue #270, B2-W2 — relocated from an inline `db.transaction` here)
        // wraps the Task update + sync enqueue + cascade in a single Dexie
        // transaction so a downstream failure rolls back the partial writes;
        // previously a crash between the task update and the cascade would
        // leave the Task flipped but board stats stale forever.
        try {
          await toggleTaskCompletionAndCascade(childTaskId);
        } catch (err) {
          console.error('Compound child toggle failed:', err);
          onFlash('Something went wrong', 'bingo');
        }
      }
    },
    [isExpired, taskMap, boardTasks, allBoardTasks, handleComplete, onFlash]
  );

  // ── Play-mode board-task write methods ─────────────────────────────────
  // The swap / remove / add modals live in the component's JSX; these methods
  // own the DB call + error flash so the write leaves the JSX (B2-W3).

  /** M3 — Cell swap: replace the given board-task's task with `newTaskId`. */
  const swapBoardTask = useCallback(
    async (boardTaskId: string, newTaskId: string): Promise<void> => {
      try {
        await updateBoardTaskAndCascade(boardTaskId, newTaskId);
      } catch (err) {
        console.error('Cell swap failed:', err);
        onFlash('Swap failed — please try again', 'bingo');
      }
    },
    [onFlash],
  );

  /** M4 — Remove the given board-task placement from this board. */
  const removeBoardTask = useCallback(
    async (boardTaskId: string): Promise<void> => {
      try {
        await removeBoardTaskFromBoard(boardTaskId);
      } catch (err) {
        console.error('Remove from board failed:', err);
        onFlash('Remove failed — please try again', 'bingo');
      }
    },
    [onFlash],
  );

  /** M4 — Add a task to the empty cell at (row, col) on this board. */
  const addTaskToCell = useCallback(
    async (taskId: string, row: number, col: number): Promise<void> => {
      try {
        await addBoardTaskToBoard(boardId, taskId, row, col);
      } catch (err) {
        console.error('Add task to cell failed:', err);
        onFlash('Add failed — please try again', 'bingo');
      }
    },
    [boardId, onFlash],
  );

  return {
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
  };
}
