import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import type { Board, TaskEvent } from '@oybc/shared';
import { db } from '../db/internal';
import { buildSquareWindowContext, type SquareWindowContext } from '../db/adapters';

// Module-scoped frozen empty array — see EMPTY_BOARD_TASKS in useBoardPlayData.ts
// for why: a stable fallback preserves React Compiler's memoization of
// downstream useMemo/useCallback deps.
const EMPTY_TASK_EVENTS = Object.freeze([]) as unknown as TaskEvent[];

/**
 * Windowed Completion (docs/WINDOWED_COMPLETION.md §Semantics): the reactive
 * read-model piece every board-square surface needs so its squares resolve
 * against THIS board's window instead of tasks' lifetime completion caches —
 * the exact bleed-green class the doc's §Task caches section forbids
 * ("Board grids ... stop reading them for anything windowed").
 *
 * One live query over `db.taskEvents` + one grouping pass, shared by every
 * consumer (`useBoardPlayData` for `BoardPlaySurface`, `RisoBoard`'s
 * read-only mini-poster, `useBoardPlay`'s edit-mode rearrange preview) so a
 * new board-square surface gets windowed reads by construction instead of by
 * remembering to wire it up ad hoc.
 *
 * @param board - The board whose window (`[board.startDate, ∞)`) squares
 *   resolve against. Only `startDate` is read, so a prospective (not yet
 *   persisted) board — e.g. the wizard preview's resolved dates — can pass
 *   `{ startDate }` directly.
 */
export function useSquareWindowContext(board: Pick<Board, 'startDate'>): SquareWindowContext {
  const allTaskEvents: TaskEvent[] =
    useLiveQuery(() => db.taskEvents.toArray(), []) ?? EMPTY_TASK_EVENTS;

  return useMemo(
    () => buildSquareWindowContext(allTaskEvents, board.startDate),
    [allTaskEvents, board.startDate],
  );
}
