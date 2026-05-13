import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  deriveSpawnedBoardName,
  fisherYatesShuffle,
  getTimeframeBoundaries,
  toLocalISO,
  type PendingTemplateSpawn,
  type Task,
} from '@oybc/shared';
import { db } from '../../db/database';
import {
  activateBoard,
  createBoard,
  updateBoard,
} from '../../db/operations/boards';
import {
  createBoardTask,
  deleteBoardTasksForBoard,
} from '../../db/operations/boardTasks';
import {
  createRecurringBoardTemplate,
  updateRecurringBoardTemplate,
} from '../../db/operations/recurringBoardTemplates';
import {
  spawnTemplateBoard,
  type SpawnResult,
} from '../../db/operations/recurringBoardSpawn';
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
 * Matches the semantics the legacy Create tab's `BoardCreatorPanel` used so the wizard
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

  const size = controller.size;
  const isOddBoard = size % 2 !== 0;
  const centerRow = Math.floor(size / 2);
  const centerCol = Math.floor(size / 2);

  // Wrap the whole write path in a single Dexie transaction so the
  // board record + its BoardTask rows commit or roll back together.
  // Splitting across sequential awaits would leave partially-updated
  // boards on disk (and in the sync queue) if one step failed mid-flight.
  // `syncQueue` is included in the scope because the inner helpers fire
  // sync entries inline after their row writes.
  let boardId: string = '';
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.syncQueue],
    async () => {
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
    },
  );

  return boardId;
}

/** Outcome of a recurring-template persist. */
export interface PersistRecurringTemplateResult {
  templateId: string;
  /** The boardId of the immediately-spawned current-window board, when
   *  this was a fresh template create. `null` for edits (no spawn) and
   *  for fresh creates where the spawn was skipped (validation
   *  failure — the template is still saved and will retry on the next
   *  Boards-tab open). */
  spawnedBoardId: string | null;
  /** Set when the spawn was skipped/failed. The template is saved
   *  regardless; the user will see the "needs attention" badge in the
   *  Profile templates list. */
  spawnSkipReason?: SpawnResult extends infer T
    ? T extends { ok: false; reason: infer R }
      ? R
      : never
    : never;
}

export interface PersistRecurringTemplateArgs {
  controller: BoardWizardController;
  userId: string;
}

/**
 * Persist path for `controller.isRecurring === true`. Branches on
 * `editingTemplateId`:
 *
 * - **Fresh create** (no `editingTemplateId`): inserts the
 *   `RecurringBoardTemplate` row, then immediately spawns the current
 *   window's board via `spawnTemplateBoard`. The two writes are
 *   sequential (each opens its own Dexie transaction); if the spawn
 *   fails (e.g. soft-deleted task race), the template still exists
 *   with `lastSpawnedWindowKey=null` and the next Boards-tab open
 *   will retry. Locked decision: first-spawn timing = immediate.
 *
 * - **Edit** (`editingTemplateId` set): updates the template via
 *   `updateRecurringBoardTemplate`. Does NOT spawn — edits don't
 *   retroactively change previously-spawned boards, and the next
 *   window's spawn will pick up the new pool naturally.
 */
export async function persistRecurringTemplate({
  controller,
  userId,
}: PersistRecurringTemplateArgs): Promise<PersistRecurringTemplateResult> {
  const trimmedName = controller.name.trim();
  const customName =
    controller.centerType === CenterSquareType.CUSTOM_FREE
      ? controller.centerCustomName.trim() || undefined
      : undefined;
  const seedTaskIds = Array.from(controller.selectedTaskIds);

  // Edit path: update + return. No spawn.
  if (controller.editingTemplateId !== null) {
    await updateRecurringBoardTemplate(controller.editingTemplateId, {
      name: trimmedName,
      timeframe: controller.timeframe,
      boardSize: controller.size,
      centerSquareType: controller.centerType,
      centerSquareCustomName: customName,
      isRandomized: controller.isRandomized,
      seedTaskIds,
      // `isActive` isn't surfaced in the wizard form (the templates
      // list owns the pause toggle), so leave it untouched on edit.
    });
    return { templateId: controller.editingTemplateId, spawnedBoardId: null };
  }

  // Fresh create path: insert template, then spawn current window.
  const template = await createRecurringBoardTemplate(userId, {
    name: trimmedName,
    timeframe: controller.timeframe,
    boardSize: controller.size,
    centerSquareType: controller.centerType,
    centerSquareCustomName: customName,
    isRandomized: controller.isRandomized,
    seedTaskIds,
    isActive: true,
  });

  // Compute the current window and spawn the board. `spawnTemplateBoard`
  // opens its own atomic transaction (Board + BoardTasks + template
  // lastSpawnedWindowKey + sync queue items). If it returns ok=false,
  // the template is intact; the Boards-tab spawn driver retries.
  const { startDate, endDate } = getTimeframeBoundaries(
    controller.timeframe,
    new Date(),
    controller.weekStartDay,
  );
  const pendingSpawn: PendingTemplateSpawn = {
    template,
    windowStart: startDate,
    windowEnd: endDate,
    suggestedName: deriveSpawnedBoardName(template, startDate),
  };

  const result = await spawnTemplateBoard(pendingSpawn);
  if (result.ok) {
    return {
      templateId: template.id,
      spawnedBoardId: result.boardId,
    };
  }
  return {
    templateId: template.id,
    spawnedBoardId: null,
    spawnSkipReason: result.reason,
  };
}
