import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  fisherYatesShuffle,
  getTimeframeBoundaries,
  toLocalISO,
  type Task,
} from '@oybc/shared';
import {
  activateBoard,
  createBoard,
  updateBoard,
} from '../../db/operations/boards';
import {
  createBoardTask,
  deleteBoardTasksForBoard,
} from '../../db/operations/boardTasks';
import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import type { TaskLibrary } from '../../pages/createPage/useTaskLibrary';

/** Per-cell placement for the preview grid and the persisted
 *  `BoardTask` rows. `null` slots only appear at the reserved centre
 *  cell for FREE / CUSTOM_FREE centre types. */
export type WizardPlacement = (Task | null)[];

/**
 * Builds the full placement array for the wizard's current selection +
 * geometry. Used as the single source of truth for both the preview
 * grid and the `createBoardTask` calls so what the user sees and what
 * gets persisted are identical.
 */
export function buildWizardPlacement(
  controller: BoardWizardController,
  library: TaskLibrary,
): WizardPlacement {
  const { size, centerType, centerTaskId, isRandomized, selectedTaskIds } = controller;
  const totalCells = size * size;
  const isOdd = size % 2 !== 0;
  const centerIdx = Math.floor(size / 2) * size + Math.floor(size / 2);

  const selected: Task[] = library.allTasks.filter((t) => selectedTaskIds.has(t.id));

  const chosenCenter: Task | null =
    isOdd && centerType === CenterSquareType.CHOSEN && centerTaskId !== null
      ? selected.find((t) => t.id === centerTaskId) ?? null
      : null;
  const others = chosenCenter !== null
    ? selected.filter((t) => t.id !== chosenCenter.id)
    : selected;

  const ordered = isRandomized ? fisherYatesShuffle([...others]) : [...others];

  const grid: WizardPlacement = new Array(totalCells).fill(null);
  let oi = 0;
  for (let i = 0; i < totalCells; i++) {
    if (i === centerIdx && isOdd) {
      if (chosenCenter !== null) {
        grid[i] = chosenCenter;
        continue;
      }
      if (
        centerType === CenterSquareType.FREE ||
        centerType === CenterSquareType.CUSTOM_FREE
      ) {
        // Reserved cell — leave null; BingoBoard renders the FREE label.
        continue;
      }
      // NONE on odd: fall through and place a regular task here.
    }
    if (oi < ordered.length) {
      grid[i] = ordered[oi++];
    }
  }
  return grid;
}

/** Resolved `startDate` / `endDate` ISO strings, or an error to surface. */
export type ResolvedDates =
  | { startDate: string; endDate: string }
  | { error: string };

/**
 * Resolves start/end ISO timestamps for the new/updated board record.
 * Mirrors the existing `BoardCreatorPanel` behaviour so the wizard
 * produces dates indistinguishable from the legacy panel's output.
 */
export function resolveWizardDates(controller: BoardWizardController): ResolvedDates {
  if (controller.timeframe !== Timeframe.CUSTOM) {
    const b = getTimeframeBoundaries(
      controller.timeframe,
      new Date(),
      controller.weekStartDay,
    );
    return { startDate: b.startDate, endDate: b.endDate };
  }
  if (!controller.customStartDate || !controller.customEndDate) {
    return { error: 'Pick a start and end date.' };
  }
  // Parse YYYY-MM-DD manually to avoid UTC shift from `new Date('YYYY-MM-DD')`.
  const [sy, sm, sd] = controller.customStartDate.split('-').map(Number);
  const [ey, em, ed] = controller.customEndDate.split('-').map(Number);
  const start = new Date(sy, sm - 1, sd, 0, 0, 0, 0);
  const end = new Date(ey, em - 1, ed, 23, 59, 59, 999);
  if (end.getTime() < start.getTime()) {
    return { error: 'End date must be on or after the start date.' };
  }
  return { startDate: toLocalISO(start), endDate: toLocalISO(end) };
}

export type WizardStatus = 'active' | 'draft';

export interface PersistWizardBoardArgs {
  controller: BoardWizardController;
  library: TaskLibrary;
  userId: string;
  /** Placement to persist. Callers should compute this once via
   *  `buildWizardPlacement` and reuse the same array for both
   *  rendering and persistence so they never drift. */
  placement: WizardPlacement;
  /** Pre-resolved start/end ISO strings. Callers should surface any
   *  `resolveWizardDates` error BEFORE calling this. */
  dates: { startDate: string; endDate: string };
  status: WizardStatus;
}

/**
 * Writes the wizard's state to the local DB (and queues sync).
 *
 * - **Fresh create** (no `draftBoardId`): `createBoard` with
 *   status=DRAFT → per-cell `createBoardTask` → if `status='active'`,
 *   flip to ACTIVE via `activateBoard` (second version bump).
 * - **Draft update** (`draftBoardId` set): `updateBoard` with the
 *   target status and all other fields → `deleteBoardTasksForBoard`
 *   (hard delete + sync DELETE) → per-cell `createBoardTask`.
 *
 * Returns the resulting `boardId`. Errors propagate.
 */
export async function persistWizardBoard({
  controller,
  userId,
  placement,
  dates,
  status,
}: PersistWizardBoardArgs): Promise<string> {
  const trimmedName = controller.name.trim();
  const customName =
    controller.centerType === CenterSquareType.CUSTOM_FREE
      ? controller.centerCustomName.trim() || undefined
      : undefined;
  const centerTaskId =
    controller.centerType === CenterSquareType.CHOSEN
      ? controller.centerTaskId ?? undefined
      : undefined;

  const sharedFields = {
    name: trimmedName,
    boardSize: controller.size,
    timeframe: controller.timeframe,
    startDate: dates.startDate,
    endDate: dates.endDate,
    centerSquareType: controller.centerType,
    centerSquareCustomName: customName,
    centerTaskId,
    isRandomized: controller.isRandomized,
  };

  let boardId: string;
  if (controller.draftBoardId !== null) {
    boardId = controller.draftBoardId;
    await updateBoard(boardId, {
      ...sharedFields,
      status: status === 'active' ? BoardStatus.ACTIVE : BoardStatus.DRAFT,
    });
    await deleteBoardTasksForBoard(boardId);
  } else {
    const board = await createBoard(userId, sharedFields);
    boardId = board.id;
  }

  const size = controller.size;
  const isOddBoard = size % 2 !== 0;
  const centerRow = Math.floor(size / 2);
  const centerCol = Math.floor(size / 2);

  for (let i = 0; i < placement.length; i++) {
    const task = placement[i];
    if (task === null) continue;
    const row = Math.floor(i / size);
    const col = i % size;
    const isCenterPos = isOddBoard && row === centerRow && col === centerCol;
    await createBoardTask({
      boardId,
      taskId: task.id,
      row,
      col,
      // Mark centre for CHOSEN (real task at centre) and NONE.
      isCenter:
        isCenterPos &&
        (controller.centerType === CenterSquareType.CHOSEN ||
          controller.centerType === CenterSquareType.NONE),
    });
  }

  if (controller.draftBoardId === null && status === 'active') {
    await activateBoard(boardId);
  }

  return boardId;
}
