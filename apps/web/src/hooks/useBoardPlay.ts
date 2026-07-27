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
import { db } from '../db/internal';
import { taskToSquareData, taskToSquareState, type SquareWindowContext } from '../db/adapters';
import { handleTaskCompletion } from '../db/operations/orchestration';
import {
  decrementSharedCounter,
  incrementSharedCounter,
  setCounterDefaultLogAmount,
} from '../db/operations/tasks';
import { resolveCreditedCounterName } from '../components/boardPlaySharedCounterUtils';
import {
  updateBoardTaskAndCascade,
  removeBoardTaskFromBoard,
  addBoardTaskToBoard,
  reorderBoardTasks,
} from '../db/operations/boardTasks';
import { updateTaskAndCascade, toggleTaskCompletionAndCascade, undoLastCounterLog, type UpdateTaskPatch } from '../db/operations/tasks';
import { updateBoardAndCascade, type UpdateActiveBoardPatch } from '../db/operations/boards';
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
   * into the rearrange-preview's `taskToSquareState`/`taskToSquareData` calls so
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
  /** Stage a removal for the given boardTaskId (empties the cell; committed on Save). */
  handleEditRemove: (boardTaskId: string) => void;
  handleEditTaskDone: (taskId: string, patch: UpdateTaskPatch) => void;
  handleRearrangeReorder: (newSlots: ArrangeSlot[]) => void;
  /**
   * Commits every staged square edit, then (board-integrity PR-4, item 3,
   * docs/BOARD_INTEGRITY.md) the board-metadata patch too — ALL in one Dexie
   * transaction. `metadataPatch` is optional only so existing non-Save
   * callers (none today) aren't forced to supply one; `BoardEditPanel`'s
   * `handleSave` always passes it, folding what used to be its own separate
   * `updateBoardAndCascade` call into this single atomic commit.
   */
  commitSquareEdits: (metadataPatch?: UpdateActiveBoardPatch) => Promise<void>;
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
  handleCompoundChildToggle: (childTaskId: string) => Promise<void>;
  // ── Board-task write methods (from the play-mode add modal) ──
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
    gridSize,
    playLocked,
    squareWindowContext,
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
  // Whether the current edit session's draft has been seeded. Distinguishes the
  // un-seeded first render (draft still [] because the seed effect runs a frame
  // after `editMode` flips) from a legitimately EMPTY draft after the user has
  // removed every square — the two are indistinguishable by `squaresDraft.length`
  // alone, and conflating them silently disabled Save / skipped the discard
  // confirm on "remove everything" (review Critical).
  const [draftSeeded, setDraftSeeded] = useState(false);

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
  // Staged removals: pre-edit placements (still live in `boardTasks` during
  // staging) absent from the current draft. Gated on `editMode` + `draftSeeded`
  // (NOT `squaresDraft.length > 0`) so the un-seeded first render doesn't briefly
  // count every placement as removed, while a legitimately empty draft (user
  // removed every square) is still counted. Mirrors iOS `editSquaresEditCount`.
  const draftBoardTaskIds = new Set(squaresDraft.map((c) => c.boardTaskId));
  const stagedRemovalCount =
    editMode && draftSeeded
      ? boardTasks.filter((bt) => !draftBoardTaskIds.has(bt.id)).length
      : 0;

  const squareEditCount =
    squaresDraft.filter((c) => c.taskId !== c.originalTaskId).length +
    taskOverrides.size +
    squaresDraft.filter(
      (c) =>
        !(c.isCenter && draftCenterType !== CenterSquareType.NONE) &&
        (c.row !== c.originalRow || c.col !== c.originalCol),
    ).length +
    stagedRemovalCount;

  // Seed the squares draft when entering edit mode; reset all draft state when
  // exiting. boardTasks is intentionally NOT in the dep array — we seed once
  // on entry and must not re-seed on live-query updates (that would clobber
  // staged changes mid-session). board is also not in deps for the same reason;
  // we read board.centerSquareType once at entry time (the snapshot rule).
  useEffect(() => {
    if (!editMode) {
      setSquaresDraft([]);
      setDraftSeeded(false);
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
    setDraftSeeded(true);
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
   * Stage a Remove for the given boardTaskId.
   * Called from the edit-mode square tap menu's "Remove from board" item.
   * Drops the cell from the draft — arrangeSlots (a useMemo over squaresDraft)
   * auto-reflects the now-empty position, and squareEditCount picks it up via
   * the staged-removal term. NO DB write happens here — the placement is
   * hard-deleted in commitSquareEdits at Save time.
   */
  const handleEditRemove = useCallback((boardTaskId: string) => {
    setSquaresDraft((prev) => prev.filter((c) => c.boardTaskId !== boardTaskId));
    // squareEditCount is derived from squaresDraft vs boardTasks — no manual increment.
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
              task, EMPTY_TASK_STEPS, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
            );
            const squareState = taskToSquareState(
              task, taskChildren, taskMap, compoundChildrenByCompound, squareWindowContext,
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
    squareWindowContext,
  ]);

  /**
   * Board-integrity PR-4, item 3 (docs/BOARD_INTEGRITY.md): Board-Edit Save
   * used to run as ~5 sequential Dexie transactions (one per staged
   * replacement, one per task-field override, one for the reorder batch, one
   * per removal, then a SEPARATE `updateBoardAndCascade` transaction back in
   * `BoardEditPanel`). A mid-sequence failure left a half-applied board with
   * only a generic "save failed" — and web's Cancel never rolled back the
   * part that DID commit.
   *
   * Fix: every step below (including the board-metadata patch, folded in as
   * step 5) now runs inside ONE outer `db.transaction(...)`. Every helper
   * called here (`updateBoardTaskAndCascade`, `updateTaskAndCascade`,
   * `reorderBoardTasks`, `removeBoardTaskFromBoard`, `updateBoardAndCascade`)
   * already opens its OWN `db.transaction('rw', [...])` internally — Dexie
   * transactions are reentrant: when a nested `db.transaction()` call's
   * requested table scope is a subset of the ALREADY-open ambient
   * transaction's scope (verified for exactly this outer scope during PR-4
   * review), Dexie joins the same underlying IndexedDB transaction instead of
   * opening a new one. So wrapping the unchanged call sequence in the outer
   * transaction below is sufficient for atomicity — no "InTxn" duplicate
   * variants were needed for any of these five ops. The outer scope is the
   * union of every table any of them touches (directly or via
   * `addToSyncQueue`/`buildWindowContext`).
   *
   * Op order is UNCHANGED from before this fix: replacements → task-field
   * overrides → reorders → removals → (new) metadata patch. A throw at any
   * step now rolls back every write from every earlier step too, so a
   * partial Save can never be observed — the board is either fully saved or
   * untouched.
   *
   * @param metadataPatch - The board-metadata patch from `BoardEditPanel`'s
   *   Save button (name/timeframe/dates/center). Optional so a future
   *   non-Save caller could commit just the square edits, but every current
   *   caller (Save) supplies it.
   */
  const commitSquareEdits = useCallback(
    async (metadataPatch?: UpdateActiveBoardPatch): Promise<void> => {
      await db.transaction(
        'rw',
        [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
        async () => {
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
          // 4. Staged removals: pre-edit placements (still un-mutated in the DB during
          //    staging) that are absent from the draft. `removeBoardTaskFromBoard`
          //    tombstones the placement + cascades + enqueues sync, leaving the
          //    cell empty; it's idempotent, so a re-run after a partial failure is
          //    safe. Loop mirrors the replacement loop above.
          const draftIds = new Set(squaresDraft.map((c) => c.boardTaskId));
          for (const bt of boardTasks) {
            if (!draftIds.has(bt.id)) {
              await removeBoardTaskFromBoard(bt.id);
            }
          }
          // 5. Board-metadata patch (name/timeframe/dates/center) — folded into
          //    this same transaction (item 3). Previously a separate
          //    `updateBoardAndCascade` call made by `BoardEditPanel` AFTER this
          //    function had already returned (and already committed).
          if (metadataPatch) {
            await updateBoardAndCascade(boardId, metadataPatch);
          }
        },
      );
    },
    [squaresDraft, taskOverrides, boardId, draftCenterType, boardTasks],
  );

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
        const { affectedBoards } = await incrementSharedCounter(sourceTaskId, amount);
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
        const { affectedBoards, effectiveDelta } = await decrementSharedCounter(sourceTaskId, amount);
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

  /**
   * Handles toggling a compound child task from the detail sheet.
   *
   * Only a placement on the CURRENT board can go through `handleComplete`, whose
   * orchestration (`handleTaskCompletion`) hard-guards `targetBt.boardId ===
   * boardId` and throws otherwise. A child placed only on ANOTHER board — or not
   * placed at all — routes through the board-agnostic
   * `toggleTaskCompletionAndCascade`, which updates the global Task + re-runs the
   * cross-board cascade so the parent compound (on THIS board, since the user is
   * opening its detail sheet) re-derives its completion + the board stats.
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

      if (currentBt) {
        await handleComplete(currentBt.id, { isCompleted: !childTask.isCompleted });
      } else {
        // Child is not on the current board (placed elsewhere, or not at all),
        // but the parent compound still derives through it — so run the
        // board-agnostic cascade to recompute bingo state + denormalised board
        // stats. `toggleTaskCompletionAndCascade` (issue #270, B2-W2 — relocated
        // from an inline `db.transaction` here) wraps the Task update + sync
        // enqueue + cascade in a single Dexie transaction so a downstream
        // failure rolls back the partial writes; previously a crash between the
        // task update and the cascade would leave the Task flipped but board
        // stats stale forever.
        try {
          await toggleTaskCompletionAndCascade(childTaskId);
        } catch (err) {
          console.error('Compound child toggle failed:', err);
          onFlash('Something went wrong', 'bingo');
        }
      }
    },
    [playLocked, taskMap, boardTasks, handleComplete, onFlash]
  );

  // ── Play-mode board-task write methods ─────────────────────────────────
  // The add modal lives in the component's JSX; this method owns the DB call +
  // error flash so the write leaves the JSX (B2-W3). (The play-mode swap/remove
  // context items were retired — those structural edits belong to Board Edit
  // mode: swap → "Replace task", remove → the edit tap-menu's staged "Remove
  // from board".)

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
    handleEditRemove,
    handleEditTaskDone,
    handleRearrangeReorder,
    commitSquareEdits,
    handleComplete,
    handleSharedCounterIncrement,
    handleSharedCounterDecrement,
    undoCounterLog,
    handleCompoundChildToggle,
    addTaskToCell,
  };
}
