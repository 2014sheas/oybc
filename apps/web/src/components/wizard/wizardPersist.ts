import {
  CenterSquareType,
  Timeframe,
  deriveSpawnedBoardName,
  getTimeframeBoundaries,
  placeBoard,
  toLocalISO,
  type PendingTemplateSpawn,
  type Task,
} from '@oybc/shared';
import {
  createRecurringBoardTemplate,
  updateRecurringBoardTemplate,
} from '../../db/operations/recurringBoardTemplates';
import {
  persistWizardBoardRows,
  persistWizardPendingTasks,
  type WizardPendingTaskWrite,
} from '../../db/operations/wizardBoard';
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
 *  cell for the FREE centre type. */
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
 *   (soft delete/tombstone + sync DELETE) → per-cell `createBoardTask`.
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
    centerTaskId,
    isRandomized: controller.isRandomized,
  };

  // Resolve the pending-tasks map. Prefer the explicit arg (snapshot
  // taken by the caller before any state mutation); fall back to the
  // controller property for callers that don't thread it separately.
  const pendingMap: Map<string, PendingTaskPayload> =
    pendingTasksArg ?? controller.pendingTasks;
  const pendingTasks: WizardPendingTaskWrite[] = Array.from(pendingMap.values());

  // The atomic write (board + BoardTask rows + Bug-#85 pending tasks, all in
  // one Dexie transaction) lives in the `persistWizardBoardRows` operation.
  // Everything above is wizard UI policy (name/center/date resolution,
  // pending-task snapshotting); the operation owns the DB write so this
  // component-tree helper no longer reaches the raw Dexie instance (B3).
  return persistWizardBoardRows({
    userId,
    // Preserve the original draft's isCore (set at first wizard launch);
    // resume + activate of a banner-launched draft stays core.
    draftBoardId: controller.draftBoardId,
    isCore: controller.isCore,
    status,
    boardFields: sharedFields,
    placement,
    size: controller.size,
    centerType: controller.centerType,
    pendingTasks,
  });
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
  /**
   * P4 — In-memory pending tasks to write atomically BEFORE the
   * template (and, for a fresh create, the spawn). When omitted, falls
   * back to `controller.pendingTasks` so callers that don't thread it
   * separately still work. Pass an explicit snapshot when the
   * controller's state may not be current at call time (mirrors
   * `PersistWizardBoardArgs.pendingTasks`'s same rationale) — e.g. the
   * cancel dialog's "Save" action.
   */
  pendingTasks?: Map<string, PendingTaskPayload>;
}

/**
 * Persist path for `controller.isRecurring === true`.
 *
 * P4 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md §P4)
 * made this the ONLY shape this path writes — the P1 legacy write-through
 * (mint-a-Pool-on-create / write-through-to-the-linked-Pool-on-edit,
 * shape-scoped via `isLegacyShapedRecord`) is retired. `controller.pulledPoolIds`
 * / `manualTaskIds` / `removedTaskIds` — P3's "PULL IN A POOL" session
 * state — are now the authoritative persisted fields, written straight
 * through:
 *
 *   - `poolIds: [...controller.pulledPoolIds]`
 *   - `manualTaskIds: Array.from(controller.manualTaskIds)`
 *   - `removedTaskIds: Array.from(controller.removedTaskIds)`
 *   - `seedTaskIds: Array.from(controller.selectedTaskIds)` — kept ONLY as
 *     a decode-compat snapshot (docs/POOLS_RECURRING.md §Migration
 *     "seedTaskIds end state") — never read back.
 *
 * **The pending-task drain (the actual P4 bug fix):** BEFORE building any
 * of the above, every pending (in-memory, not-yet-persisted) task in the
 * FULL `controller.selectedTaskIds` — not just a placed subset — is
 * written via `persistWizardPendingTasks`. The prior implementation only
 * ever read `controller.selectedTaskIds` into a Pool/template without
 * writing the underlying Task row for a pending (wizard-inline-created)
 * task, so `resolveMix`'s resolvable-id filter silently and permanently
 * dropped it from the mix — if enough pending tasks were involved, the mix
 * could fall below the fillable floor and the window would skip forever
 * with `pool_too_small`. The FULL selection (not a placed-today subset) is
 * drained because a repeating board's future windows draw from the whole
 * pool, not just today's dealt cells.
 *
 * Branches on `editingTemplateId`:
 * - **Edit**: `updateRecurringBoardTemplate` with the native fields above.
 *   No spawn — edits don't retroactively change previously-spawned boards;
 *   the next window's spawn naturally picks up the new mix.
 * - **Fresh create**: `createRecurringBoardTemplate` with the native
 *   fields, then immediately spawns the current window's board via
 *   `spawnTemplateBoard`. If the spawn fails (e.g. a genuinely-unresolvable
 *   mix), the template still exists with `lastSpawnedWindowKey=null` and
 *   the next Boards-tab open will retry. Locked decision: first-spawn
 *   timing = immediate.
 */
export async function persistRecurringTemplate({
  controller,
  userId,
  pendingTasks: pendingTasksArg,
}: PersistRecurringTemplateArgs): Promise<PersistRecurringTemplateResult> {
  const trimmedName = controller.name.trim();

  // ── THE FIX — drain pending tasks for the FULL selection first ────────
  const pendingMap: Map<string, PendingTaskPayload> = pendingTasksArg ?? controller.pendingTasks;
  await persistWizardPendingTasks(
    Array.from(pendingMap.values()),
    controller.selectedTaskIds,
  );

  const poolIds = [...controller.pulledPoolIds];
  const manualTaskIds = Array.from(controller.manualTaskIds);
  const removedTaskIds = Array.from(controller.removedTaskIds);
  // Decode-compat snapshot only — never read back after this write (see
  // this function's docstring / docs/POOLS_RECURRING.md §Migration).
  const seedTaskIds = Array.from(controller.selectedTaskIds);

  if (controller.editingTemplateId !== null) {
    const editingTemplateId = controller.editingTemplateId;
    await updateRecurringBoardTemplate(editingTemplateId, {
      name: trimmedName,
      timeframe: controller.timeframe,
      boardSize: controller.size,
      centerSquareType: controller.centerType,
      isRandomized: controller.isRandomized,
      poolIds,
      manualTaskIds,
      removedTaskIds,
      // `isActive` isn't surfaced in the wizard form (the templates list
      // owns the pause toggle), so leave it untouched on edit.
      // `seedTaskIds` intentionally omitted — left verbatim/stale, never
      // read after P1 (docs/POOLS_RECURRING.md §Migration "seedTaskIds
      // end state").
    });
    return { templateId: editingTemplateId, spawnedBoardId: null };
  }

  const template = await createRecurringBoardTemplate(userId, {
    name: trimmedName,
    timeframe: controller.timeframe,
    boardSize: controller.size,
    centerSquareType: controller.centerType,
    isRandomized: controller.isRandomized,
    seedTaskIds,
    isActive: true,
    poolIds,
    manualTaskIds,
    removedTaskIds,
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
