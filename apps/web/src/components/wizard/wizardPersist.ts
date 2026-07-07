import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  Timeframe,
  deriveSpawnedBoardName,
  getTimeframeBoundaries,
  placeBoard,
  toLocalISO,
  type CompoundChild,
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
import { addToSyncQueue } from '../../db/operations/syncQueue';
import {
  spawnTemplateBoard,
  type SpawnResult,
} from '../../db/operations/recurringBoardSpawn';
// `generateUUID` / `currentTimestamp` no longer needed here — pending-task
// sync writes now route through `addToSyncQueue` which owns both.
import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';
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
 *
 * Bug #85 — `pendingTasks` (when supplied) are merged into the candidate
 * pool so newly-created (not-yet-persisted) tasks appear in the preview
 * and placement just like library tasks. The optional parameter means
 * callers that don't pass it (e.g. `BoardWizardPreviewStep` via the
 * library prop) still compile; `BoardWizardPage` passes both.
 */
export function buildWizardPlacement(
  controller: BoardWizardController,
  library: TaskLibrary,
  pendingTasksArg?: Map<string, PendingTaskPayload>,
): WizardPlacement {
  const { size, centerType, centerTaskId, isRandomized, selectedTaskIds } = controller;
  const isOdd = size % 2 !== 0;

  // Merge pending (in-memory, not-yet-DB) tasks with the live library.
  // Pending tasks win on id collision (shouldn't happen, but defensive).
  const pendingMap = pendingTasksArg ?? controller.pendingTasks;
  const libraryById = new Map<string, Task>(library.allTasks.map((t) => [t.id, t]));
  for (const [id, payload] of pendingMap) {
    libraryById.set(id, payload.task);
  }

  // Preserve library order for non-randomized boards (post-`always-
  // randomize`, isRandomized is true everywhere in production, but the
  // ordering still matters for snapshot determinism and any legacy /
  // test path that toggles it). Library order is title-sorted in
  // `useTaskLibrary`, so deterministic given the same selected set.
  // Pending tasks (not in the library order) are appended after so
  // they still appear in the placement.
  const selectedSet = selectedTaskIds;
  const fromLibrary = library.allTasks.filter((t) => selectedSet.has(t.id));
  const fromLibraryIds = new Set(fromLibrary.map((t) => t.id));
  const pendingExtras: Task[] = [];
  for (const id of selectedSet) {
    if (fromLibraryIds.has(id)) continue;
    const t = libraryById.get(id);
    if (t !== undefined) pendingExtras.push(t);
  }
  const selected: Task[] = [...fromLibrary, ...pendingExtras];

  const chosenCenter: Task | null =
    isOdd && centerType === CenterSquareType.CHOSEN && centerTaskId !== null
      ? selected.find((t) => t.id === centerTaskId) ?? null
      : null;

  // Delegate the cell walk to the shared `placeBoard` core (@oybc/bingo-core,
  // re-exported through @oybc/shared). The preamble above is wizard UI policy
  // (pending-task merge, library ordering, chosenCenter lookup); the geometry
  // + center handling + fill are the shared placement math. Passing NONE for
  // even grids preserves today's "even grid = no special center" behavior
  // (placeBoard also derives that internally via getCenterSquareIndex, so this
  // is belt-and-suspenders). No `rng` → defaults to Math.random, matching the
  // old `fisherYatesShuffle([...others])`.
  return placeBoard({
    items: selected,
    gridSize: size,
    centerType: isOdd ? centerType : CenterSquareType.NONE,
    chosenCenterId: chosenCenter?.id,
    randomize: isRandomized,
  });
}

/** Resolved `startDate` / `endDate` ISO strings, or an error to surface.
 *  `endDate` is undefined for INDEFINITE (ongoing) boards. */
export type ResolvedDates =
  | { startDate: string; endDate?: string }
  | { error: string };

/**
 * Resolves start/end ISO timestamps for the new/updated board record.
 * Matches the semantics the legacy Create tab's `BoardCreatorPanel` used so the wizard
 * produces dates indistinguishable from the legacy panel's output.
 *
 * @param controller  Wizard state.
 * @param now         Reference date for non-CUSTOM windows. Defaults to
 *   `new Date()`. The core-board browser passes a future date here so a
 *   banner-launched "Plan ahead" flow spawns the window the user picked
 *   instead of always landing on today's window.
 */
export function resolveWizardDates(
  controller: BoardWizardController,
  now: Date = new Date(),
): ResolvedDates {
  // Indefinite (ongoing) boards have no deadline. Honor the chosen Start date
  // (the Custom section's Start picker is shown for ongoing boards too) — it's
  // the creation anchor + achievement-window lower bound; fall back to today
  // when unset. endDate stays undefined so the board carries no deadline.
  if (controller.timeframe === Timeframe.INDEFINITE) {
    let start: Date;
    if (controller.customStartDate) {
      const [sy, sm, sd] = controller.customStartDate.split('-').map(Number);
      start = new Date(sy, sm - 1, sd, 0, 0, 0, 0);
    } else {
      start = new Date(now);
      start.setHours(0, 0, 0, 0);
    }
    return { startDate: toLocalISO(start), endDate: undefined };
  }
  if (controller.timeframe !== Timeframe.CUSTOM) {
    const b = getTimeframeBoundaries(
      controller.timeframe,
      now,
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
   *  `resolveWizardDates` error BEFORE calling this. `endDate` is
   *  undefined for INDEFINITE (ongoing) boards — createBoard/updateBoard
   *  then store/clear it as nullish. */
  dates: { startDate: string; endDate?: string };
  status: WizardStatus;
  /**
   * Bug #85 — In-memory pending tasks to write atomically BEFORE the
   * board + board_tasks rows. When omitted, falls back to
   * `controller.pendingTasks` so callers that don't thread it
   * separately still work. Pass an explicit value when the controller's
   * state may not be current (e.g., after a `reset()` call).
   */
  pendingTasks?: Map<string, PendingTaskPayload>;
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
  pendingTasks: pendingTasksArg,
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

  // Resolve the pending-tasks map. Prefer the explicit arg (snapshot
  // taken by the caller before any state mutation); fall back to the
  // controller property for callers that don't thread it separately.
  const pendingMap: Map<string, PendingTaskPayload> =
    pendingTasksArg ?? controller.pendingTasks;

  // Wrap the whole write path in a single Dexie transaction so the
  // board record + its BoardTask rows commit or roll back together.
  // Splitting across sequential awaits would leave partially-updated
  // boards on disk (and in the sync queue) if one step failed mid-flight.
  // `syncQueue` is included in the scope because the inner helpers fire
  // sync entries inline after their row writes.
  // Bug #85 — tasks + compoundChildren tables are added to the scope so
  // pending tasks can be written atomically before board_tasks that
  // reference them.
  let boardId: string = '';
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      // ── Bug #85: Write pending tasks first ────────────────────────────
      // Pending tasks (created inside the wizard's New Task sheet) have
      // never been written to the DB. Write them now — parent task first,
      // then child tasks, then compound_children links — before any
      // board_tasks rows that would reference them. All inside the same
      // Dexie transaction so a board-write failure rolls everything back.
      //
      // Route every enqueue through `addToSyncQueue` (not a direct
      // `db.syncQueue.add`) so the DEV playground-user-1 guard fires
      // here too — otherwise playground sessions can leak pending
      // tasks into the real sync queue.
      // Bug #85 — only persist pending tasks that are actually placed on the
      // board. Deselecting a task purges it from pendingMap (toggleTaskSelection),
      // but guard here too: a stray pending payload must never be written as an
      // orphan Task row — it would show in the library (web has no
      // createdInWizard filter yet) and reappear on draft resume.
      const placedTaskIds = new Set(
        placement.map((t) => t?.id).filter((id): id is string => id != null),
      );
      for (const payload of pendingMap.values()) {
        if (!placedTaskIds.has(payload.task.id)) continue;
        await db.tasks.add(payload.task);
        await addToSyncQueue(
          'tasks',
          payload.task.id,
          SyncOperationType.CREATE,
          payload.task,
        );
        for (const childTask of payload.childTasks) {
          await db.tasks.add(childTask);
          await addToSyncQueue(
            'tasks',
            childTask.id,
            SyncOperationType.CREATE,
            childTask,
          );
        }
        for (const link of payload.childLinks) {
          await db.compoundChildren.add(link as CompoundChild);
          await addToSyncQueue(
            'compoundChildren',
            link.id,
            SyncOperationType.CREATE,
            link,
          );
        }
      }

      // ── Board + BoardTask rows ─────────────────────────────────────────
      if (controller.draftBoardId !== null) {
        boardId = controller.draftBoardId;
        // Preserve the original draft's isCore (set at first wizard
        // launch); resume + activate of a banner-launched draft stays
        // core. updateBoard merges Partial<Board> so omitting isCore
        // here is a no-op when it was already correct on the draft.
        await updateBoard(boardId, {
          ...sharedFields,
          status: status === 'active' ? BoardStatus.ACTIVE : BoardStatus.DRAFT,
        });
        await deleteBoardTasksForBoard(boardId);
      } else {
        const board = await createBoard(userId, sharedFields, { isCore: controller.isCore });
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
          // Mark centre only for CHOSEN (a real task pinned at centre). NONE
          // holds an ordinary task (isCenter false); FREE/CUSTOM_FREE have a
          // null centre slot (no row). Marking NONE was a bug — it renders a
          // gold "FREE" cell over the task on iOS (which reads isCenter) and
          // syncs there via board_tasks.
          isCenter:
            isCenterPos && controller.centerType === CenterSquareType.CHOSEN,
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

  // Compute the spawn window and create the board. `spawnTemplateBoard`
  // opens its own atomic transaction (Board + BoardTasks + template
  // lastSpawnedWindowKey + sync queue items). If it returns ok=false,
  // the template is intact; the Boards-tab spawn driver retries.
  //
  // The reference date defaults to "now" — the historic recurring-banner
  // flow — but the core-board browser may pass a future date via
  // `controller.targetWindowDate` so the first-spawn matches the window
  // the user actually picked.
  const { startDate, endDate } = getTimeframeBoundaries(
    controller.timeframe,
    controller.targetWindowDate ?? new Date(),
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
