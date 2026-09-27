import {
  CenterSquareType,
  effectiveCenter,
  isLegacyChosenCenterLocked,
  shuffleUnlockedSlots,
  type BoardTask,
} from '@oybc/shared';
import type { UpdateTaskPatch } from '../db/operations/tasks';
import type { PendingTaskPayload } from '../pages/createPage/useCreateFormState';
import { deriveSquareEditCount, type SquareDraftCell } from './squareEditCount';

export type { SquareDraftCell } from './squareEditCount';

/**
 * The squares-editor staged-draft state (Board Edit redesign slice 3, T2) —
 * pure, framework-free so it is unit-testable without a DOM/React renderer
 * (this repo's Vitest config is `environment: 'node'`, `.test.ts` only —
 * see `vitest.config.ts`). `useSquaresEditDraft.ts` is the thin React
 * wrapper (`useReducer`-style: every function below takes the current
 * state and returns the next one) plus the render-facing `EditSlot`
 * builder, which needs `Task`/`BoardCellModel` data and so stays untested
 * directly (covered by e2e).
 */
export interface SquaresEditDraftState {
  cells: SquareDraftCell[];
  taskOverrides: Map<string, UpdateTaskPatch>;
  /** The draft's stored center-type value — legacy CHOSEN preserved verbatim
   *  until Save (D1/D2); read it through `effectiveCenter` everywhere else. */
  draftCenterType: CenterSquareType;
  /** ids of live placements (present at seed) staged for removal. */
  removedIds: Set<string>;
  /** Set once `shuffle()` has run (D11 — collapses however many cells moved into ONE edit). */
  shuffled: boolean;
}

/** A slot that holds position: the pinned center or a locked square. */
export function isFixedSlot<S extends { isPinned: boolean } | undefined>(slot: S): boolean {
  return !!slot && slot.isPinned;
}

/**
 * Cascade helper for drag-to-insert (D8): lift `dragCid` out of its current
 * slot and insert it before `slotIndex`, flowing the other movable tiles
 * around it. Ported verbatim from `ArrangeGrid.tsx`'s `reorderToSlot`, kept
 * generic over any slot shape carrying `cellId`/`isPinned` so both the full
 * render-facing `EditSlot` (with a model, for the grid's live drag preview)
 * and a minimal test literal (`{cellId, isPinned}`) can reuse it.
 */
export function reorderToSlot<S extends { cellId: string; isPinned: boolean }>(
  slots: S[],
  dragCid: string,
  slotIndex: number,
): S[] {
  if (isFixedSlot(slots[slotIndex])) return slots;
  const movableIndices = slots.map((_, i) => i).filter((i) => !isFixedSlot(slots[i]));
  const toK = movableIndices.indexOf(slotIndex);
  if (toK < 0) return slots;
  const order = movableIndices.map((i) => slots[i]);
  const dragItem = order.find((s) => s.cellId === dragCid);
  if (!dragItem) return slots;
  const without = order.filter((s) => s.cellId !== dragCid);
  without.splice(toK, 0, dragItem);
  const next = slots.slice();
  movableIndices.forEach((slotI, k) => {
    next[slotI] = without[k];
  });
  return next;
}

/** `effectiveCenter(draftCenterType) === FREE` — the pinned positional center. */
export function isPinnedCenter(draftCenterType: CenterSquareType): boolean {
  return effectiveCenter(draftCenterType) === CenterSquareType.FREE;
}

/** Seed the draft from the live `boardTasks` snapshot on edit-mode entry
 *  (D1 — the effective lock baseline: `bt.isLocked || isLegacyChosenCenterLocked(...)`). */
export function seedDraft(
  boardTasks: BoardTask[],
  boardCenterType: CenterSquareType,
  gridSize: number,
): SquaresEditDraftState {
  const half = Math.floor(gridSize / 2);
  const isOddBoard = gridSize % 2 === 1;
  return {
    cells: boardTasks.map((bt) => {
      const atPositionalCenter = isOddBoard && bt.row === half && bt.col === half;
      const effLocked =
        bt.isLocked === true ||
        (atPositionalCenter && isLegacyChosenCenterLocked(boardCenterType, bt.row, bt.col, gridSize));
      return {
        cellId: bt.id,
        row: bt.row,
        col: bt.col,
        taskId: bt.taskId,
        isLocked: effLocked,
        originalTaskId: bt.taskId,
        originalRow: bt.row,
        originalCol: bt.col,
        originalLocked: effLocked,
      };
    }),
    taskOverrides: new Map(),
    draftCenterType: boardCenterType,
    removedIds: new Set(),
    shuffled: false,
  };
}

export function stageAdd(
  state: SquaresEditDraftState,
  row: number,
  col: number,
  pick: { taskId: string } | { pending: PendingTaskPayload },
): SquaresEditDraftState {
  const taskId = 'pending' in pick ? pick.pending.task.id : pick.taskId;
  const pending = 'pending' in pick ? pick.pending : undefined;
  const cell: SquareDraftCell = {
    cellId: `new-${row}-${col}-${taskId}`,
    row,
    col,
    taskId,
    pending,
    isLocked: false,
    originalTaskId: null,
    originalRow: row,
    originalCol: col,
    originalLocked: false,
  };
  return { ...state, cells: [...state.cells, cell] };
}

export function stageReplace(
  state: SquaresEditDraftState,
  cellId: string,
  pick: { taskId: string } | { pending: PendingTaskPayload },
): SquaresEditDraftState {
  const taskId = 'pending' in pick ? pick.pending.task.id : pick.taskId;
  const pending = 'pending' in pick ? pick.pending : undefined;
  return {
    ...state,
    cells: state.cells.map((c) => (c.cellId === cellId ? { ...c, taskId, pending } : c)),
  };
}

export function stageRemove(state: SquaresEditDraftState, cellId: string): SquaresEditDraftState {
  const target = state.cells.find((c) => c.cellId === cellId);
  const removedIds =
    target && target.originalTaskId !== null
      ? new Set(state.removedIds).add(target.cellId)
      : state.removedIds;
  return { ...state, cells: state.cells.filter((c) => c.cellId !== cellId), removedIds };
}

export function toggleLock(state: SquaresEditDraftState, cellId: string): SquaresEditDraftState {
  return {
    ...state,
    cells: state.cells.map((c) => (c.cellId === cellId ? { ...c, isLocked: !c.isLocked } : c)),
  };
}

export function stageTaskEdit(
  state: SquaresEditDraftState,
  taskId: string,
  patch: UpdateTaskPatch,
): SquaresEditDraftState {
  const taskOverrides = new Map(state.taskOverrides);
  taskOverrides.set(taskId, { ...(taskOverrides.get(taskId) ?? {}), ...patch });
  return { ...state, taskOverrides };
}

/** Commit a drag-to-insert reorder — the grid's full post-drag slot order. */
export function commitReorder<S extends { cellId: string; isCenter: boolean; isEmpty: boolean }>(
  state: SquaresEditDraftState,
  newSlots: S[],
  gridSize: number,
): SquaresEditDraftState {
  const newPositions = new Map<string, { row: number; col: number }>();
  newSlots.forEach((slot, i) => {
    if (!slot.isEmpty && !slot.isCenter) {
      newPositions.set(slot.cellId, { row: Math.floor(i / gridSize), col: i % gridSize });
    }
  });
  return {
    ...state,
    cells: state.cells.map((c) => {
      const pos = newPositions.get(c.cellId);
      return pos ? { ...c, row: pos.row, col: pos.col } : c;
    }),
  };
}

export type KeyboardMoveDir = 'up' | 'down' | 'left' | 'right';

/** D9 — Alt+Arrow: swap a movable cell with its neighbor one slot over. */
export function stageKeyboardMove(
  state: SquaresEditDraftState,
  cellId: string,
  dir: KeyboardMoveDir,
  gridSize: number,
): { state: SquaresEditDraftState; moved: boolean; blocked?: 'locked' | 'bounds'; row?: number; col?: number } {
  const cell = state.cells.find((c) => c.cellId === cellId);
  if (!cell) return { state, moved: false };
  const [dr, dc] =
    dir === 'up' ? [-1, 0] : dir === 'down' ? [1, 0] : dir === 'left' ? [0, -1] : [0, 1];
  const targetRow = cell.row + dr;
  const targetCol = cell.col + dc;
  if (targetRow < 0 || targetRow >= gridSize || targetCol < 0 || targetCol >= gridSize) {
    return { state, moved: false, blocked: 'bounds' };
  }
  const half = Math.floor(gridSize / 2);
  const isOddBoard = gridSize % 2 === 1;
  const targetIsPinnedCenter =
    isOddBoard && isPinnedCenter(state.draftCenterType) && targetRow === half && targetCol === half;
  const targetCell = state.cells.find((c) => c.row === targetRow && c.col === targetCol);
  if (targetIsPinnedCenter || targetCell?.isLocked) {
    return { state, moved: false, blocked: 'locked' };
  }
  return {
    state: {
      ...state,
      cells: state.cells.map((c) => {
        if (c.cellId === cellId) return { ...c, row: targetRow, col: targetCol };
        if (targetCell && c.cellId === targetCell.cellId) return { ...c, row: cell.row, col: cell.col };
        return c;
      }),
    },
    moved: true,
    row: targetRow,
    col: targetCol,
  };
}

/** D10 — Shuffle: every non-fixed slot (locked cells + the pinned center excluded). */
export function shuffleCells(
  state: SquaresEditDraftState,
  gridSize: number,
  rng?: () => number,
): SquaresEditDraftState {
  const half = Math.floor(gridSize / 2);
  const isOddBoard = gridSize % 2 === 1;
  const pinned = isPinnedCenter(state.draftCenterType);
  const total = gridSize * gridSize;
  const byPos = new Map<number, SquareDraftCell>();
  for (const c of state.cells) byPos.set(c.row * gridSize + c.col, c);
  const centerIndex = isOddBoard ? half * gridSize + half : -1;

  const fixed: boolean[] = [];
  const slotValues: (string | null)[] = [];
  for (let i = 0; i < total; i++) {
    const c = byPos.get(i);
    fixed.push(i === centerIndex && pinned ? true : c?.isLocked === true);
    slotValues.push(c ? c.cellId : null);
  }
  const shuffled = shuffleUnlockedSlots(slotValues, fixed, rng);
  return {
    ...state,
    cells: state.cells.map((c) => {
      if (c.isLocked) return c;
      const newIndex = shuffled.indexOf(c.cellId);
      if (newIndex < 0) return c;
      return { ...c, row: Math.floor(newIndex / gridSize), col: newIndex % gridSize };
    }),
    shuffled: true,
  };
}

/** D16 — FREE center: also stages the removal of any task at the center cell. */
export function setCenterFree(state: SquaresEditDraftState, gridSize: number): SquaresEditDraftState {
  const half = Math.floor(gridSize / 2);
  const isOddBoard = gridSize % 2 === 1;
  if (!isOddBoard) return { ...state, draftCenterType: CenterSquareType.FREE };
  const centerCell = state.cells.find((c) => c.row === half && c.col === half);
  const removedIds =
    centerCell && centerCell.originalTaskId !== null
      ? new Set(state.removedIds).add(centerCell.cellId)
      : state.removedIds;
  return {
    ...state,
    draftCenterType: CenterSquareType.FREE,
    cells: state.cells.filter((c) => !(c.row === half && c.col === half)),
    removedIds,
  };
}

/** D16 — task square: the center becomes an empty (tappable-to-add) cell. */
export function setCenterTask(state: SquaresEditDraftState): SquaresEditDraftState {
  return { ...state, draftCenterType: CenterSquareType.NONE };
}

// ─── Derived ────────────────────────────────────────────────────────────────

/** OQ8 — Shuffle needs at least 2 non-fixed slots holding a task. */
export function deriveCanShuffle(state: SquaresEditDraftState, gridSize: number): boolean {
  const half = Math.floor(gridSize / 2);
  const isOddBoard = gridSize % 2 === 1;
  const pinned = isPinnedCenter(state.draftCenterType);
  let unfixedWithTask = 0;
  for (const c of state.cells) {
    const atCenter = isOddBoard && c.row === half && c.col === half && pinned;
    if (!atCenter && !c.isLocked) unfixedWithTask++;
  }
  return unfixedWithTask >= 2;
}

/** D2's `keepLocked` argument — the draft's CURRENT lock for the positional-center cell, if any. */
export function deriveCenterCellKeepLocked(state: SquaresEditDraftState, gridSize: number): boolean {
  const half = Math.floor(gridSize / 2);
  if (gridSize % 2 !== 1) return false;
  return state.cells.find((c) => c.row === half && c.col === half)?.isLocked ?? false;
}

export interface DeriveEditCountInput {
  state: SquaresEditDraftState;
  /** The board's own stored `centerSquareType` (baseline for `centerChanged`). */
  boardCenterType: CenterSquareType;
}

/** D11 — the squares editor's derived edit count. */
export function deriveEditCount({ state, boardCenterType }: DeriveEditCountInput): number {
  const centerChanged = effectiveCenter(state.draftCenterType) !== effectiveCenter(boardCenterType);
  return deriveSquareEditCount({
    cells: state.cells,
    taskOverrides: state.taskOverrides,
    removedCount: state.removedIds.size,
    centerChanged,
    shuffled: state.shuffled,
  });
}

