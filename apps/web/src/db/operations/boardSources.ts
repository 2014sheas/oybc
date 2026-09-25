import { db } from '../internal';
import { healBoardNames } from './boardNames';
import { fetchCompoundChildrenByCompoundIds } from './compoundChildren';
import {
  boardDisplayName,
  boardWindowEnd,
  BoardStatus,
  isEligibleSourceBoard,
  isEventOwningTask,
  isSourceSupplyTask,
  isWindowStampedDerived,
  pickSeriesInstance,
  poolSourceSupplyById,
  availableSupplyIds,
  resolveDerivedCounterWindowState,
  resolveTaskWindowState,
  sourcesForRecord,
  TaskType,
  toLocalISO,
  type Board,
  type BoardSourceSupply,
  type BoardWindow,
  type CompoundChild,
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
 * the source board's window; window-stamped derived counters resolve
 * from their ROOT's events in their own window
 * (`resolveDerivedCounterWindowState`, the kernel rule); compound /
 * achievement / hub-linked derived counting read the lifetime
 * `Task.isCompleted` cache (the documented per-cell carve-out — these
 * surfaces carry no compound/achievement evaluation context of their own).
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
  /**
   * §Member rules (B3, RC4) — each event-owning COUNTING member's windowed
   * count (Σ non-deleted increment deltas inside THIS board's window), the
   * same number the source board's own squares display. Keyed by task id;
   * a member with no entry has made no measurable progress here (or isn't
   * an event-owning counter at all — compounds, achievements and derived
   * counters get no entry; a window-stamped derived row's window count is
   * deliberately NOT fed into this prefill map).
   *
   * Feeds the one-off wizard's "remaining" target prefill: pull a
   * 3-of-10-done counter onto a fresh one-off board and its member rule is
   * seeded with `remainingTarget(10, 3) = 7`.
   */
  windowCountByTaskId: Record<string, number>;
  /**
   * §Member rules (B3, RC5) — the source board's OWN window, so a caller
   * can pro-rate an auto target (`effectiveMemberTarget`) without a second
   * board read.
   */
  sourceWindow: BoardWindow;
}

/** One BOARDS-section row for the "Add from a pool or board" sheet. */
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
  const windowCountByTaskId: Record<string, number> = {};
  for (const bt of rows) {
    const task = tasksById[bt.taskId];
    // `isSourceSupplyTask`: achievements never enter source supply —
    // hand-placed watchers on the pulled board stay on that board only.
    if (task === undefined || task.isDeleted || !isSourceSupplyTask(task) || seen.has(task.id))
      continue;
    seen.add(task.id);
    supply.push(task.id);
    let isDone: boolean;
    // A window-stamped derived counter is done by its ROOT's increments inside
    // its own window — the kernel's rule (docs §Derived-task carve-out,
    // amended 2026-09-23) — never the one-way latch, which a later window's
    // logs can set. Its window count is deliberately NOT fed to the prefill
    // (`windowCountByTaskId`): that map stays event-owning counters only.
    const derived = resolveDerivedCounterWindowState(task, eventsByTaskId);
    if (derived) {
      isDone = derived.isCompleted;
    } else if (isEventOwningTask(task)) {
      const state = resolveTaskWindowState(
        task,
        eventsByTaskId[task.id] ?? [],
        board.startDate,
        boardWindowEnd(board),
      );
      isDone = state.isCompleted;
      // §Member rules (B3, RC4) — the same windowed resolution that decides
      // "done" also yields the count the remaining-target prefill needs; a
      // counter's progress in THIS window is read once, never re-derived.
      if (task.type === TaskType.COUNTING) windowCountByTaskId[task.id] = state.count;
    } else {
      isDone = task.isCompleted;
    }
    if (isDone) done.add(task.id);
  }
  return {
    displayName: boardDisplayName(board),
    supplyTaskIds: supply,
    doneTaskIds: done,
    windowCountByTaskId,
    sourceWindow: {
      timeframe: board.timeframe,
      startDate: board.startDate ?? null,
      endDate: board.endDate ?? null,
    },
  };
}

/**
 * The task ids whose events {@link resolveBoardSourceSupply} reads for a
 * board's placed `tasks`: every placed id, plus the ROOT of each
 * window-stamped derived row (its done-state resolves from the root's events,
 * and a root is never placed itself).
 *
 * @param tasks - The board's placed tasks.
 * @returns Distinct ids to load events for.
 */
export function supplyEventTaskIds(tasks: Iterable<Task>): string[] {
  const ids = new Set<string>();
  for (const t of tasks) {
    ids.add(t.id);
    if (t.sharedCounterId && isWindowStampedDerived(t)) ids.add(t.sharedCounterId);
  }
  return [...ids];
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
  const eventTaskIds = supplyEventTaskIds(tasks);
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  if (eventTaskIds.length > 0) {
    const events = await db.taskEvents.where('taskId').anyOf(eventTaskIds).toArray();
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
  // `pickSeriesInstance`: latest startDate, lowest id on a tie — two
  // offline devices can each spawn the same window, and the id key keeps
  // web and iOS pulling from the same instance.
  if (containing.length > 0) return pickSeriesInstance(containing);
  const started = instances.filter((b) => b.startDate <= reference);
  return pickSeriesInstance(started.length > 0 ? started : instances);
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
 * BOARDS rows for the "Add from a pool or board" sheet: ACTIVE, non-deleted
 * boards with squares/done counts from the same predicate the member
 * rows use. Matches iOS eligibility exactly (ACTIVE only).
 */
export async function fetchSourceSheetBoardEntries(
  userId: string,
): Promise<SourceSheetBoardEntry[]> {
  // No bare `userId` index on boards — a `.filter` scan is fine at local
  // data sizes.
  //
  // Eligibility is the `isEligibleSourceBoard` rule, shared with
  // the Swift twin. This sheet previously filtered on
  // `status === ACTIVE` alone: a board whose window closes unfinished
  // stays ACTIVE forever, so every stale core board stayed on offer.
  // Names are healed because a legacy daily core board is stored as the
  // literal "Today" — the rows here and the SEARCH that filters them both
  // read `board.name`.
  const now = new Date();
  const boards = healBoardNames(
    await db.boards.filter((b) => b.userId === userId && !b.isDeleted).toArray(),
  ).filter((b) => isEligibleSourceBoard(b, now));
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
  /** B2 (§Member rules — *Resolution pipeline* step 1): live
   *  `compound_children` rows for every COMPOUND member of `supplies`, so a
   *  reader can run `applyMemberRules` (the Split-up expansion) before
   *  counting. Empty when the supplies carry no compound. */
  childrenByCompoundId: Record<string, CompoundChild[]>;
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
      supplies.push({
        source,
        supplyTaskIds: availableSupplyIds(source, info?.supplyTaskIds ?? [], info?.doneTaskIds),
      });
    }
    byTemplateId[entry.template.id] = {
      supplies,
      deadBoardSourceIds,
      manualTaskIds: entry.manualTaskIds,
      childrenByCompoundId: {},
    };
  }

  // B2 (§Member rules step 1) — the Split-up expansion needs each COMPOUND
  // member's children, and the readers that then count the expansion need
  // those children in `tasksById` (a part the map doesn't know is a part the
  // roster silently drops). One links fetch + one tasks fetch for the whole
  // roster, after `tasksById` exists — which member ids are compounds is not
  // knowable before it.
  const compoundIds = new Set<string>();
  for (const resolution of Object.values(byTemplateId)) {
    for (const supply of resolution.supplies) {
      for (const id of supply.supplyTaskIds) {
        if (tasksById[id]?.type === TaskType.COMPOUND) compoundIds.add(id);
      }
    }
  }
  if (compoundIds.size > 0) {
    const childrenByCompoundId: Record<string, CompoundChild[]> = {};
    const childTaskIds = new Set<string>();
    for (const link of await fetchCompoundChildrenByCompoundIds([...compoundIds])) {
      (childrenByCompoundId[link.compoundTaskId] ??= []).push(link);
      if (tasksById[link.childTaskId] === undefined) childTaskIds.add(link.childTaskId);
    }
    if (childTaskIds.size > 0) {
      for (const t of await db.tasks.where('id').anyOf([...childTaskIds]).toArray()) {
        tasksById[t.id] = t;
      }
    }
    for (const resolution of Object.values(byTemplateId)) {
      for (const supply of resolution.supplies) {
        for (const id of supply.supplyTaskIds) {
          const links = childrenByCompoundId[id];
          if (links !== undefined) resolution.childrenByCompoundId[id] = links;
        }
      }
    }
  }
  return { byTemplateId, tasksById };
}
