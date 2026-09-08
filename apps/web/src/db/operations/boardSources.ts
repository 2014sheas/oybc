import { db } from '../internal';
import {
  BoardStatus,
  isEventOwningTask,
  resolveTaskWindowState,
  type Board,
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
    if (task === undefined || task.isDeleted || seen.has(task.id)) continue;
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

/**
 * Resolve one board's source supply for the wizard. `null` when the board
 * is missing or soft-deleted (an unresolvable source supplies nothing —
 * the caller renders/contributes an empty supply, never blocks).
 */
export async function fetchBoardSourceSupply(
  boardId: string,
): Promise<BoardSourceSupplyInfo | null> {
  const board = await db.boards.get(boardId);
  if (board === undefined || board.isDeleted) return null;
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
