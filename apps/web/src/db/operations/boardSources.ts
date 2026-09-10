import { db } from '../internal';
import {
  BoardStatus,
  isEventOwningTask,
  isSourceSupplyTask,
  poolSourceSupplyById,
  resolveTaskWindowState,
  sourcesForRecord,
  toLocalISO,
  type Board,
  type BoardSourceSupply,
  type RecurringBoardTemplate,
  type Task,
  type TaskEvent,
} from '@oybc/shared';

/**
 * boardSources.ts — Board Sources P4 (docs/BOARD_SOURCES.md §Boards as
 * sources). The web half of board-kind source resolution: a pulled
 * board's RAW supply (its live placed task ids) plus each member's
 * done-state in THAT board's window, for the wizard's member rows
 * ("done" ✓), subtitles ("6 squares · 4 done"), the source sheet's
 * BOARDS rows, and the spawn path (which calls `resolveBoardSupply`
 * inside its own transaction — the wizard-time and spawn-time
 * resolutions share this one code path, the P3 lock).
 *
 * Done-state predicate mirrors iOS
 * `AppDatabase+BoardSources.resolveSupply` / the play surfaces:
 * event-owning primitives resolve via `resolveTaskWindowState` against
 * the source board's window; compound / achievement / derived counting
 * read the lifetime `Task.isCompleted` cache (the documented per-cell
 * carve-out — these surfaces carry no compound/achievement evaluation
 * context of their own).
 */

/** iOS twin: `BoardSourceSupplyInfo` (`AppDatabase+BoardSources.swift`). */
export interface BoardSourceSupplyInfo {
  /** The source board's display name (for the row title). */
  displayName: string;
  /** Deduped, placement-ordered, non-deleted placed task ids — the RAW
   *  supply (before excludes/filter). */
  supplyTaskIds: string[];
  /** The subset of `supplyTaskIds` complete in the board's window. */
  doneTaskIds: Set<string>;
}

/** One BOARDS-section row for the "Add a pool or board" sheet. */
export interface SourceSheetBoardEntry {
  board: Board;
  squares: number;
  done: number;
}

/**
 * Pure resolution over caller-supplied reads — callable from the spawn
 * transaction (which owns its own `tasksById`/`eventsByTaskId` snapshots)
 * and from the fetch helpers below. `boardTaskRows` are the board's raw
 * `BoardTask` rows (any order; deleted rows tolerated).
 */
export function resolveBoardSourceSupply(
  board: Board,
  boardTaskRows: Array<{
    taskId: string;
    row: number;
    col: number;
    isDeleted?: boolean;
  }>,
  tasksById: Record<string, Task>,
  eventsByTaskId: Record<string, TaskEvent[]>,
): BoardSourceSupplyInfo {
  const rows = boardTaskRows
    .filter((bt) => !bt.isDeleted)
    .sort((a, b) => a.row - b.row || a.col - b.col);
  const seen = new Set<string>();
  const supply: string[] = [];
  const done = new Set<string>();
  for (const bt of rows) {
    const task = tasksById[bt.taskId];
    // `isSourceSupplyTask`: achievements never enter source supply —
    // hand-placed watchers on the pulled board stay on that board only.
    if (task === undefined || task.isDeleted || !isSourceSupplyTask(task) || seen.has(task.id))
      continue;
    seen.add(task.id);
    supply.push(task.id);
    const isDone = isEventOwningTask(task)
      ? resolveTaskWindowState(
          task,
          eventsByTaskId[task.id] ?? [],
          board.startDate,
        ).isCompleted
      : task.isCompleted;
    if (isDone) done.add(task.id);
  }
  return { displayName: board.name, supplyTaskIds: supply, doneTaskIds: done };
}

/** Batched per-board reads (three queries), shared by the fetch helpers. */
async function resolveFromDb(board: Board): Promise<BoardSourceSupplyInfo> {
  const rows = await db.boardTasks.where('boardId').equals(board.id).toArray();
  const liveRows = rows.filter((bt) => !bt.isDeleted);
  const taskIds = [...new Set(liveRows.map((bt) => bt.taskId))];
  const tasks =
    taskIds.length > 0 ? await db.tasks.where('id').anyOf(taskIds).toArray() : [];
  const tasksById: Record<string, Task> = {};
  for (const t of tasks) tasksById[t.id] = t;
  const eventOwningIds = tasks.filter((t) => isEventOwningTask(t)).map((t) => t.id);
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  if (eventOwningIds.length > 0) {
    const events = await db.taskEvents.where('taskId').anyOf(eventOwningIds).toArray();
    for (const e of events) {
      if (e.isDeleted) continue;
      (eventsByTaskId[e.taskId] ??= []).push(e);
    }
  }
  return resolveBoardSourceSupply(board, liveRows, tasksById, eventsByTaskId);
}

/** True when a board row can serve as a live source instance. */
function isLiveSourceBoard(board: Board): boolean {
  return !board.isDeleted && board.status !== BoardStatus.ARCHIVED;
}

/**
 * Series binding (loose-ends sweep 2026-09-09 — docs/BOARD_SOURCES.md
 * §Boards as sources, now implemented as designed): resolve a STORED
 * board-source id to the board that should supply squares right now.
 *
 * - A one-off board (no `spawnedFromTemplateId`) resolves to itself while
 *   it is live, else `null`.
 * - A board that belongs to a recurring series binds to the SERIES: the
 *   pull hops to the series' live instance — the one whose window
 *   contains `reference` when it exists, else the newest live instance
 *   whose window has started, else the newest live instance. Old
 *   archived windows therefore never kill the pull; only a series with
 *   NO live instance (or a stored one-off that is gone) resolves `null`
 *   — which the spawn maps to the `source_board_missing` ask.
 *
 * @param storedBoardId - The id the source row stored at pull time.
 * @param reference - ISO instant to resolve "the live window" against —
 *   the spawn passes its window start; wizard/roster callers default to
 *   now. MUST be in the same LOCAL-wall-clock ISO format board
 *   `startDate`/`endDate` use (`toLocalISO` — no Z suffix): the
 *   comparisons are lexicographic, and a UTC `toISOString()` instant
 *   mis-sorts against local boundaries near local midnight in any
 *   non-UTC zone (review-caught Critical, 2026-09-09).
 */
export async function resolveSourceBoard(
  storedBoardId: string,
  reference: string = toLocalISO(new Date()),
): Promise<Board | null> {
  const stored = await db.boards.get(storedBoardId);
  if (stored === undefined) return null;
  const seriesId = stored.spawnedFromTemplateId;
  if (!seriesId) {
    return isLiveSourceBoard(stored) ? stored : null;
  }
  const instances = (
    await db.boards.filter((b) => b.spawnedFromTemplateId === seriesId).toArray()
  ).filter(isLiveSourceBoard);
  if (instances.length === 0) return null;
  const containing = instances.filter(
    (b) => b.startDate <= reference && (b.endDate === undefined || reference <= b.endDate),
  );
  if (containing.length > 0) {
    containing.sort((a, b) => b.startDate.localeCompare(a.startDate));
    return containing[0];
  }
  const started = instances.filter((b) => b.startDate <= reference);
  const pool = started.length > 0 ? started : instances;
  pool.sort((a, b) => b.startDate.localeCompare(a.startDate));
  return pool[0];
}

/**
 * Resolve one board's source supply for the wizard. Series-binding aware:
 * the stored id hops to the series' live instance (see
 * `resolveSourceBoard`). `null` when nothing live resolves (an
 * unresolvable source supplies nothing — the caller renders/contributes
 * an empty supply, never blocks).
 */
export async function fetchBoardSourceSupply(
  boardId: string,
  reference?: string,
): Promise<BoardSourceSupplyInfo | null> {
  const board = await resolveSourceBoard(boardId, reference);
  if (board === null) return null;
  return resolveFromDb(board);
}

/**
 * BOARDS rows for the "Add a pool or board" sheet: ACTIVE, non-deleted
 * boards with squares/done counts from the same predicate the member
 * rows use. Matches iOS eligibility exactly (ACTIVE only — deliberately
 * narrower than `useSourceBoards`' active+recently-completed set, which
 * serves the library sheet's "From a board…" copy flow instead).
 */
export async function fetchSourceSheetBoardEntries(
  userId: string,
): Promise<SourceSheetBoardEntry[]> {
  // No bare `userId` index on boards — the `.filter` scan matches the
  // `fetchRecurringBoardTemplates` pattern (local data sizes).
  const boards = await db.boards
    .filter((b) => b.userId === userId && b.status === BoardStatus.ACTIVE && !b.isDeleted)
    .toArray();
  const entries: SourceSheetBoardEntry[] = [];
  for (const board of boards) {
    const info = await resolveFromDb(board);
    entries.push({
      board,
      squares: info.supplyTaskIds.length,
      done: info.doneTaskIds.size,
    });
  }
  return entries.sort((a, b) => b.board.updatedAt.localeCompare(a.board.updatedAt));
}

/** Per-template result of {@link fetchTemplateSupplyResolution}. */
export interface TemplateSupplyResolution {
  /** The record's resolved supplies (pool + board kinds, 'todo' applied). */
  supplies: BoardSourceSupply[];
  /** Board-kind source ids whose board is missing/deleted/archived — the
   *  spawn would skip this template with `source_board_missing`. */
  deadBoardSourceIds: string[];
  /** The record's effective hand-added layer (the un-migrated M2 rule:
   *  a record with no generalized fields treats `seedTaskIds` as manual). */
  manualTaskIds: string[];
}

/**
 * Batched, sources-native supply resolution for a roster of templates
 * (loose-ends sweep 2026-09-09 — the Board-settings health/preview used
 * to resolve via the legacy trio, so board-kind sources read as empty
 * and ranges/the counter-family rule were invisible). One boards fetch +
 * one pools fetch + one tasks fetch across the whole roster; board
 * supplies resolve through the same reader the spawn uses.
 *
 * @returns per-template resolutions plus a combined id → Task map
 *   covering every pool member, board member, and manual id (for family
 *   maps, previews, and deleted-manual checks).
 */
export async function fetchTemplateSupplyResolution(
  templates: RecurringBoardTemplate[],
): Promise<{
  byTemplateId: Record<string, TemplateSupplyResolution>;
  tasksById: Record<string, Task>;
}> {
  const perTemplateSources = templates.map((t) => {
    const isUnmigrated =
      t.sources === undefined &&
      t.poolIds === undefined &&
      t.manualTaskIds === undefined &&
      t.removedTaskIds === undefined;
    return {
      template: t,
      sources: sourcesForRecord(t),
      manualTaskIds: isUnmigrated ? t.seedTaskIds : (t.manualTaskIds ?? []),
    };
  });

  const allPoolIds = new Set<string>();
  const allBoardIds = new Set<string>();
  for (const entry of perTemplateSources) {
    for (const source of entry.sources) {
      if (source.kind === 'pool') allPoolIds.add(source.sourceId);
      else allBoardIds.add(source.sourceId);
    }
  }

  const pools =
    allPoolIds.size > 0
      ? await db.pools.where('id').anyOf([...allPoolIds]).toArray()
      : [];
  const poolsById = Object.fromEntries(pools.map((p) => [p.id, p]));

  // Series binding — each stored board id resolves through
  // `resolveSourceBoard` (hop to the series' live instance; null = dead).
  const resolvedByStoredId = new Map<string, Board | null>();
  const supplyByStoredId = new Map<string, BoardSourceSupplyInfo>();
  for (const storedId of allBoardIds) {
    const live = await resolveSourceBoard(storedId);
    resolvedByStoredId.set(storedId, live);
    if (live !== null) supplyByStoredId.set(storedId, await resolveFromDb(live));
  }

  // Combined task universe: pool members + manual + board members.
  const allTaskIds = new Set<string>();
  for (const p of pools) for (const id of p.taskIds) allTaskIds.add(id);
  for (const entry of perTemplateSources) {
    for (const id of entry.manualTaskIds) allTaskIds.add(id);
  }
  for (const info of supplyByStoredId.values()) {
    for (const id of info.supplyTaskIds) allTaskIds.add(id);
  }
  const tasks =
    allTaskIds.size > 0
      ? await db.tasks.where('id').anyOf([...allTaskIds]).toArray()
      : [];
  const tasksById: Record<string, Task> = Object.fromEntries(tasks.map((t) => [t.id, t]));

  const byTemplateId: Record<string, TemplateSupplyResolution> = {};
  for (const entry of perTemplateSources) {
    const supplies: BoardSourceSupply[] = [];
    const deadBoardSourceIds: string[] = [];
    for (const source of entry.sources) {
      if (source.kind === 'pool') {
        supplies.push({
          source,
          supplyTaskIds: poolSourceSupplyById(source.sourceId, poolsById, tasksById),
        });
        continue;
      }
      const board = resolvedByStoredId.get(source.sourceId) ?? null;
      if (board === null) {
        deadBoardSourceIds.push(source.sourceId);
        supplies.push({ source, supplyTaskIds: [] });
        continue;
      }
      const info = supplyByStoredId.get(source.sourceId);
      const raw = info?.supplyTaskIds ?? [];
      supplies.push({
        source,
        supplyTaskIds:
          source.filter === 'todo' && info
            ? raw.filter((id) => !info.doneTaskIds.has(id))
            : raw,
      });
    }
    byTemplateId[entry.template.id] = {
      supplies,
      deadBoardSourceIds,
      manualTaskIds: entry.manualTaskIds,
    };
  }
  return { byTemplateId, tasksById };
}
