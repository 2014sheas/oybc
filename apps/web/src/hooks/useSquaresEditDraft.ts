import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  CenterSquareType,
  type Board,
  type BoardSize,
  type BoardTask,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { taskToSquareData, taskToSquareState, type SquareWindowContext } from '../db/adapters';
import type { UpdateTaskPatch } from '../db/operations/tasks';
import type { PendingTaskPayload } from '../pages/createPage/useCreateFormState';
import { type BoardCellModel } from '../components/board/RisoBoardCell';
import { freeCellModel, toBoardCellModel } from '../components/board/cellModel';
import { isSquareDirty, type SquareDraftCell } from './squareEditCount';
import {
  commitReorder as commitReorderPure,
  deriveCanShuffle,
  deriveCenterCellKeepLocked,
  deriveEditCount,
  isPinnedCenter as isPinnedCenterPure,
  seedDraft,
  setCenterFree as setCenterFreePure,
  setCenterTask as setCenterTaskPure,
  shuffleCells,
  stageAdd as stageAddPure,
  stageKeyboardMove as stageKeyboardMovePure,
  stageRemove as stageRemovePure,
  stageReplace as stageReplacePure,
  stageTaskEdit as stageTaskEditPure,
  toggleLock as toggleLockPure,
  type KeyboardMoveDir,
  type SquaresEditDraftState,
} from './squaresEditReducer';

export type { SquareDraftCell } from './squareEditCount';
export { reorderToSlot, isFixedSlot } from './squaresEditReducer';

/**
 * One slot in the flat row-major squares-editor grid (Board Edit redesign
 * slice 3, D7–D10) — the render-facing shape (carries a `BoardCellModel`).
 * The ONE grid for both tap (menu/add) and hold-drag, since slice 3 retires
 * the Edit tasks ⇄ Rearrange sub-modes. Evolved from Phase 3's `ArrangeSlot`.
 */
export interface EditSlot {
  cellId: string;
  isCenter: boolean;
  /** A locked square OR the pinned FREE center — never lifts, never a drop target. */
  isPinned: boolean;
  isEmpty: boolean;
  model: BoardCellModel | null;
}

export interface UseSquaresEditDraftParams {
  board: Board;
  editMode: boolean;
  boardTasks: BoardTask[];
  taskMap: Record<string, Task>;
  compoundChildrenByCompound: Record<string, CompoundChild[]>;
  gridSize: BoardSize;
  squareWindowContext: SquareWindowContext;
}

export interface UseSquaresEditDraftResult {
  /** Row-major flat slots (length gridSize²) for `SquaresEditGrid`. */
  slots: EditSlot[];
  cells: SquareDraftCell[];
  cellsById: Record<string, SquareDraftCell>;
  taskOverrides: Map<string, UpdateTaskPatch>;
  /** The draft's stored center-type value — legacy CHOSEN preserved verbatim
   *  until Save (D1/D2); read it through `effectiveCenter` everywhere else. */
  draftCenterType: CenterSquareType;
  /** `effectiveCenter(draftCenterType) === FREE` — the pinned positional center. */
  isPinnedCenter: boolean;
  editCount: number;
  canShuffle: boolean;
  /** Resolve a task for display, applying any staged override. */
  resolveTask: (taskId: string) => Task | undefined;
  stageAdd: (row: number, col: number, pick: { taskId: string } | { pending: PendingTaskPayload }) => void;
  stageReplace: (cellId: string, pick: { taskId: string } | { pending: PendingTaskPayload }) => void;
  stageRemove: (cellId: string) => void;
  toggleLock: (cellId: string) => void;
  stageTaskEdit: (taskId: string, patch: UpdateTaskPatch) => void;
  /** Commit a drag-to-insert reorder (the grid's full post-drag slot order). */
  commitReorder: (newSlots: EditSlot[]) => void;
  /** D9 — Alt+Arrow: swap a movable cell with its neighbor one slot over. */
  stageKeyboardMove: (
    cellId: string,
    dir: KeyboardMoveDir,
  ) => { moved: boolean; blocked?: 'locked' | 'bounds'; row?: number; col?: number };
  shuffle: (rng?: () => number) => void;
  setCenterFree: () => void;
  setCenterTask: () => void;
  /** Whether the on-disk board is still legacy CHOSEN (drives Save's D2 conversion). */
  isLegacyChosenOnDisk: boolean;
  /** The draft's CURRENT lock state for the positional-center cell, if any —
   *  `normalizeLegacyChosenCenter`'s `keepLocked` argument. */
  centerCellKeepLocked: boolean;
  /** ids of live placements (present at seed) staged for removal — Save's removal step. */
  removedBoardTaskIds: string[];
}

const EMPTY_STATE: SquaresEditDraftState = {
  cells: [],
  taskOverrides: new Map(),
  draftCenterType: CenterSquareType.NONE,
  removedIds: new Set(),
  shuffled: false,
  originalCenterCellId: null,
};

/**
 * The squares-editor staged-draft engine (Board Edit redesign slice 3, T2).
 * Extracted + extended from `useBoardPlay.ts` (moved out of it entirely): a
 * position-keyed draft that also represents staged NEW tasks (`pending`),
 * one Free⇄Task center toggle, Shuffle, and keyboard moves — replacing the
 * slice-1/2 sub-mode split (Edit tasks ⇄ Rearrange).
 *
 * Thin React wrapper over the pure `squaresEditReducer.ts` — every mutation
 * below delegates to a pure `(state, ...) => state` function so the state
 * machine itself is unit-testable without a DOM/React renderer (this repo's
 * Vitest config is `.test.ts`-only, `environment: 'node'`). This hook only
 * owns the `useState`, the seed/reset effect, and the render-facing `slots`
 * builder (which needs `Task`/`BoardCellModel` data).
 */
export function useSquaresEditDraft(
  params: UseSquaresEditDraftParams,
): UseSquaresEditDraftResult {
  const { board, editMode, boardTasks, taskMap, compoundChildrenByCompound, gridSize, squareWindowContext } = params;

  const [state, setState] = useState<SquaresEditDraftState>(EMPTY_STATE);
  const [seeded, setSeeded] = useState(false);

  const isOddBoard = gridSize % 2 === 1;
  const half = Math.floor(gridSize / 2);
  const boardCenterType = board.centerSquareType as CenterSquareType;

  // Seed on entry; reset on exit. `boardTasks`/`board` intentionally excluded
  // from deps (slice-1/2 precedent) — we seed ONCE on entry and must not
  // re-seed on a live-query update mid-session.
  useEffect(() => {
    if (!editMode) {
      setState(EMPTY_STATE);
      setSeeded(false);
      return;
    }
    setState(seedDraft(boardTasks, boardCenterType, gridSize));
    setSeeded(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editMode]);

  const stageAdd = useCallback(
    (row: number, col: number, pick: { taskId: string } | { pending: PendingTaskPayload }) =>
      setState((s) => stageAddPure(s, row, col, pick)),
    [],
  );
  const stageReplace = useCallback(
    (cellId: string, pick: { taskId: string } | { pending: PendingTaskPayload }) =>
      setState((s) => stageReplacePure(s, cellId, pick)),
    [],
  );
  const stageRemove = useCallback((cellId: string) => setState((s) => stageRemovePure(s, cellId)), []);
  const toggleLock = useCallback((cellId: string) => setState((s) => toggleLockPure(s, cellId)), []);
  const stageTaskEdit = useCallback(
    (taskId: string, patch: UpdateTaskPatch) => setState((s) => stageTaskEditPure(s, taskId, patch)),
    [],
  );
  const commitReorder = useCallback(
    (newSlots: EditSlot[]) => setState((s) => commitReorderPure(s, newSlots, gridSize)),
    [gridSize],
  );
  // NOT a functional setState updater (unlike the siblings above): the
  // caller needs a SYNCHRONOUS {moved, blocked} result (to announce it via
  // aria-live, D9) — a functional updater's callback isn't guaranteed to run
  // before this function returns, but a keystroke's re-render always
  // happens before the next one, so reading `state` from the closure here
  // is safe.
  const stageKeyboardMove = useCallback(
    (cellId: string, dir: KeyboardMoveDir) => {
      const result = stageKeyboardMovePure(state, cellId, dir, gridSize);
      setState(result.state);
      return { moved: result.moved, blocked: result.blocked, row: result.row, col: result.col };
    },
    [state, gridSize],
  );
  const shuffle = useCallback(
    (rng?: () => number) => setState((s) => shuffleCells(s, gridSize, rng)),
    [gridSize],
  );
  const setCenterFree = useCallback(() => setState((s) => setCenterFreePure(s, gridSize)), [gridSize]);
  const setCenterTask = useCallback(() => setState((s) => setCenterTaskPure(s)), []);

  const resolveTask = useCallback(
    (taskId: string): Task | undefined => {
      const base = taskMap[taskId] ?? state.cells.find((c) => c.taskId === taskId)?.pending?.task;
      if (!base) return undefined;
      const override = state.taskOverrides.get(taskId);
      return override ? { ...base, ...(override as Partial<Task>) } : base;
    },
    [taskMap, state.cells, state.taskOverrides],
  );

  const editCount = seeded ? deriveEditCount({ state, boardCenterType }) : 0;
  const canShuffle = deriveCanShuffle(state, gridSize);
  const centerCellKeepLocked = deriveCenterCellKeepLocked(state, gridSize);
  const pinnedCenter = isPinnedCenterPure(state.draftCenterType);

  const slots = useMemo<EditSlot[]>(() => {
    if (!editMode) return [];
    const result: EditSlot[] = [];
    for (let r = 0; r < gridSize; r++) {
      for (let c = 0; c < gridSize; c++) {
        const atPositionalCenter = isOddBoard && r === half && c === half;
        const draftCell = state.cells.find((cell) => cell.row === r && cell.col === c);

        if (atPositionalCenter && pinnedCenter && !draftCell) {
          result.push({
            cellId: `center-${r}-${c}`,
            isCenter: true,
            isPinned: true,
            isEmpty: false,
            model: freeCellModel(`center-${r}-${c}`),
          });
        } else if (draftCell) {
          const task = resolveTask(draftCell.taskId);
          let model: BoardCellModel | null = null;
          if (task) {
            const children = compoundChildrenByCompound[task.id] ?? [];
            const squareData = taskToSquareData(task, children, taskMap, compoundChildrenByCompound, squareWindowContext);
            const squareState = taskToSquareState(task, children, taskMap, compoundChildrenByCompound, squareWindowContext);
            model = toBoardCellModel({
              key: draftCell.cellId,
              task,
              done: squareState.isCompleted,
              currentCount: squareData.type === 'counting' ? squareState.currentCount : undefined,
              locked: draftCell.isLocked,
              dirty: isSquareDirty(draftCell, state.taskOverrides),
            });
          }
          result.push({
            cellId: draftCell.cellId,
            isCenter: atPositionalCenter && pinnedCenter,
            isPinned: draftCell.isLocked,
            isEmpty: false,
            model,
          });
        } else {
          result.push({
            cellId: `empty-${r}-${c}`,
            isCenter: false,
            isPinned: false,
            isEmpty: true,
            model: null,
          });
        }
      }
    }
    return result;
  }, [
    editMode,
    gridSize,
    half,
    isOddBoard,
    pinnedCenter,
    state.cells,
    state.taskOverrides,
    taskMap,
    compoundChildrenByCompound,
    squareWindowContext,
    resolveTask,
  ]);

  const cellsById: Record<string, SquareDraftCell> = {};
  for (const c of state.cells) cellsById[c.cellId] = c;

  return {
    slots,
    cells: state.cells,
    cellsById,
    taskOverrides: state.taskOverrides,
    draftCenterType: state.draftCenterType,
    isPinnedCenter: pinnedCenter,
    editCount,
    canShuffle,
    resolveTask,
    stageAdd,
    stageReplace,
    stageRemove,
    toggleLock,
    stageTaskEdit,
    commitReorder,
    stageKeyboardMove,
    shuffle,
    setCenterFree,
    setCenterTask,
    isLegacyChosenOnDisk: (board.centerSquareType as CenterSquareType) === CenterSquareType.CHOSEN,
    centerCellKeepLocked,
    removedBoardTaskIds: [...state.removedIds],
  };
}
