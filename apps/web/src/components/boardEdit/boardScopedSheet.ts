import { useEffect, useState } from 'react';
import type { Task } from '@oybc/shared';
import { fetchTasksByIds } from '../../db/operations';
import { fetchWouldForkOnBoard } from '../../db/operations/boardScopedEdit';
import { applyStepToChildTask, type ChildPatch, type TaskEditPatch } from '../../db/taskEditPatch';

/**
 * Board-scoped task edits (docs/BOARD_SCOPED_TASK_EDITS.md §8) — the square
 * sheet's scope control. The scope shows as a control label, never as a
 * caption; the one sentence lives in the first-fork confirm body (an allowed
 * copy category). iOS twin: `SquareEditTaskSheet.forkDoneLabel` /
 * `forkConfirmBody` / `wouldFork(...)`.
 */

/** Done's label when the Save would fork the task. */
export const FORK_DONE_LABEL = 'Save for this board';

/** The first-fork confirm body (spec §1, verbatim). */
export const FORK_CONFIRM_BODY = 'Applies to this board only. Other boards keep the original.';

/**
 * The sheet's Done label.
 *
 * @param wouldFork - Whether the Save would fork.
 * @returns "Save for this board" for a fork, else "Done".
 */
export function sheetDoneLabel(wouldFork: boolean): string {
  return wouldFork ? FORK_DONE_LABEL : 'Done';
}

/**
 * Whether Done must first show the fork confirm — a fork that this board's
 * edit session has not confirmed yet.
 *
 * @param wouldFork - Whether the Save would fork.
 * @param confirmed - Whether this edit session already confirmed a fork.
 * @returns `true` to show the confirm.
 */
export function needsForkConfirm(wouldFork: boolean, confirmed: boolean): boolean {
  return wouldFork && !confirmed;
}

/** What the sheet knows about forks on this board, once loaded. */
export interface ForkCheck {
  /** Ids (the task, its sub-tasks) a board-scoped edit would fork. */
  forking: ReadonlySet<string>;
  /** Stored rows of those ids — the baseline a sub-task step is compared to. */
  rows: Readonly<Record<string, Task>>;
}

const NO_FORKS: ForkCheck = { forking: new Set(), rows: {} };

/**
 * Whether a compound-editor step changes its stored sub-task — the same
 * comparison the Save's `applyStagedCompoundChildEdits` makes.
 *
 * @param row - The stored sub-task (absent = nothing to change).
 * @param step - The editor's step for it.
 * @returns `true` when the Save would write the sub-task.
 */
export function childStepChanged(row: Task | undefined, step: ChildPatch): boolean {
  const title = step.title.trim();
  if (!row || step.markedDeleted || title.length === 0) return false;
  const next = applyStepToChildTask(row, step, title);
  return (
    next.title !== row.title ||
    (next.action ?? '') !== (row.action ?? '') ||
    (next.unit ?? '') !== (row.unit ?? '') ||
    next.maxCount !== row.maxCount
  );
}

/**
 * Whether the sheet's Save would fork anything: the task itself, or a
 * sub-task the compound editor changes that is placed on another board.
 *
 * @param taskId - The sheet's task.
 * @param draft - The open compound editor's draft (`null` when not shown).
 * @param check - The loaded {@link ForkCheck}.
 * @returns `true` when the label must read "Save for this board".
 */
export function sheetWouldFork(taskId: string, draft: TaskEditPatch | null, check: ForkCheck): boolean {
  if (check.forking.has(taskId)) return true;
  return (draft?.children ?? []).some(
    (c) => c.childTaskId != null && check.forking.has(c.childTaskId) && childStepChanged(check.rows[c.childTaskId], c),
  );
}

/**
 * Loads which of `ids` a board-scoped edit on `boardId` would fork, plus
 * their stored rows. `null` while loading — the sheet keeps Done disabled
 * until it resolves, so the label never flips after first paint and a quick
 * tap cannot skip the confirm. No board ⇒ nothing forks (resolved at once).
 *
 * @param ids - The sheet's task id, then its sub-task ids (blanks ignored).
 * @param boardId - The board being edited.
 * @returns The check, or `null` while loading.
 */
export function useForkCheck(ids: string[], boardId: string | undefined): ForkCheck | null {
  const key = [...new Set(ids.filter(Boolean))].join('|');
  const [state, setState] = useState<{ key: string; check: ForkCheck } | null>(null);
  useEffect(() => {
    if (!boardId) return;
    let cancelled = false;
    const unique = key.split('|').filter(Boolean);
    void (async () => {
      try {
        const flags = await Promise.all(unique.map((id) => fetchWouldForkOnBoard(id, boardId)));
        const rows: Record<string, Task> = {};
        for (const t of await fetchTasksByIds(unique)) rows[t.id] = t;
        const forking = new Set(unique.filter((_, i) => flags[i]));
        if (!cancelled) setState({ key, check: { forking, rows } });
      } catch (e) {
        console.error('[BoardEditTaskSheet] fork check failed', e);
        if (!cancelled) setState({ key, check: NO_FORKS });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [key, boardId]);
  if (!boardId) return NO_FORKS;
  return state?.key === key ? state.check : null;
}
