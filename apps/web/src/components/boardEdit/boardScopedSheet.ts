import { useEffect, useState } from 'react';
import { fetchWouldForkOnBoard } from '../../db/operations/boardScopedEdit';

/**
 * Board-scoped task edits (docs/BOARD_SCOPED_TASK_EDITS.md §8) — the square
 * sheet's scope control. The scope shows as a control label, never as a
 * caption; the one sentence lives in the first-fork confirm body (an allowed
 * copy category). iOS twin: `SquareEditTaskSheet.forkDoneLabel` /
 * `forkConfirmBody`.
 */

/** Done's label when the Save would fork the task. */
export const FORK_DONE_LABEL = 'Save for this board';

/** The first-fork confirm body (spec §1, verbatim). */
export const FORK_CONFIRM_BODY = 'Applies to this board only. Other boards keep the original.';

/**
 * The sheet's Done label.
 *
 * @param wouldFork - Whether the Save would fork the sheet's task.
 * @returns "Save for this board" for a fork, else "Done".
 */
export function sheetDoneLabel(wouldFork: boolean): string {
  return wouldFork ? FORK_DONE_LABEL : 'Done';
}

/**
 * Whether Done must first show the fork confirm — a fork that this board's
 * edit session has not confirmed yet.
 *
 * @param wouldFork - Whether the Save would fork the sheet's task.
 * @param confirmed - Whether this edit session already confirmed a fork.
 * @returns `true` to show the confirm.
 */
export function needsForkConfirm(wouldFork: boolean, confirmed: boolean): boolean {
  return wouldFork && !confirmed;
}

/**
 * Whether a Board Edit of `taskId` on `boardId` would fork — read once per
 * sheet from the same test the Save runs. `false` while loading, with no
 * board, or on a read failure (the Save still decides on its own).
 *
 * @param taskId - The sheet's task.
 * @param boardId - The board being edited (absent = never forks).
 * @returns The fork flag.
 */
export function useWouldForkOnBoard(taskId: string, boardId: string | undefined): boolean {
  const [wouldFork, setWouldFork] = useState(false);
  useEffect(() => {
    if (!boardId) return;
    let cancelled = false;
    fetchWouldForkOnBoard(taskId, boardId)
      .then((v) => {
        if (!cancelled) setWouldFork(v);
      })
      .catch((e: unknown) => console.error('[BoardEditTaskSheet] fork check failed', e));
    return () => {
      cancelled = true;
    };
  }, [taskId, boardId]);
  return wouldFork;
}
