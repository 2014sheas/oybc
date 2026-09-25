import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { boardWindowEnd, type Board, type TaskEvent } from '@oybc/shared';
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
 * @param board - The board whose window (`[board.startDate, board.endDate]`,
 *   inclusive; open-ended when `endDate` is absent — 2026-09-24 amendment of
 *   WC Decision 1) squares resolve against. Only `startDate` / `endDate` are
 *   read, so a prospective (not yet persisted) board — e.g. the wizard
 *   preview's resolved dates — can pass `{ startDate, endDate }` directly.
 * @returns The board's square window context (memoized on events + bounds).
 */
export function useSquareWindowContext(
  board: Pick<Board, 'startDate' | 'endDate'>,
): SquareWindowContext {
  const windowEnd = boardWindowEnd(board);
  const allTaskEvents: TaskEvent[] =
    useLiveQuery(() => db.taskEvents.toArray(), []) ?? EMPTY_TASK_EVENTS;

  return useMemo(
    () => buildSquareWindowContext(allTaskEvents, board.startDate, windowEnd),
    [allTaskEvents, board.startDate, windowEnd],
  );
}
