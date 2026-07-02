import type { Task } from '../types/task';
import type { BoardTask } from '../types/boardTask';
import { BoardStatus } from '../constants/enums';

/**
 * Filters the task library to the set that should appear in library-browse
 * surfaces (the Tasks tab list, the wizard "add from library" picker).
 *
 * Rule — a task is HIDDEN iff it is wizard-born (`createdInWizard === true`)
 * AND it has no placement on a live, non-draft board. Concretely, a
 * wizard-born task is hidden when it lives ONLY on draft boards, or has no
 * live placement at all (removed from the wizard pool — its Task row lingers
 * after persist drops the `board_task` — or its only board was deleted).
 * Everything else is visible: standalone/copied tasks (`createdInWizard`
 * falsy) are never hidden, and a wizard-born task with at least one
 * active/completed placement is visible.
 *
 * Mirror of the iOS `TaskLibraryViewModel.computeBrowsableTasks`
 * (`streaks.ts ↔ Streaks.swift`-style parity). Pure and fully derived at read
 * time — no clearing logic: a hidden wizard-orphan reappears automatically the
 * moment it lands on a non-draft board.
 *
 * Compound children inherit their parent compound's placements — a wizard-born
 * inline subtask is never *directly* placed (it lives under its parent), so
 * without inheritance it would look like a placement-less orphan and hide
 * forever. With inheritance it's visible exactly when its parent compound is
 * (keeping wizard-created subtasks pool-addable once the board goes active).
 *
 * @param tasks - candidate library tasks (already user-scoped + non-deleted).
 * @param boardTasks - all `board_task` placement rows.
 * @param boardStatusById - non-deleted `boardId → status`. Placements on
 *   missing (deleted) boards are ignored — a board absent from this map is
 *   treated as no live placement.
 * @param childToParents - child taskId → parent compound taskId(s). A child's
 *   effective placements = its own ∪ its parents'. Omit for a flat library.
 */
export function computeBrowsableTasks(
  tasks: Task[],
  boardTasks: BoardTask[],
  boardStatusById: Record<string, BoardStatus>,
  childToParents: Record<string, string[]> = {},
): Task[] {
  // taskId → set of non-deleted board ids it's placed on.
  const placementsByTask: Record<string, Set<string>> = {};
  for (const bt of boardTasks) {
    if (!boardStatusById[bt.boardId]) continue; // deleted / absent board → ignore
    (placementsByTask[bt.taskId] ??= new Set<string>()).add(bt.boardId);
  }
  return tasks.filter((task) => {
    if (!task.createdInWizard) return true;
    // Effective placements: own + inherited from parent compound(s).
    const boardIds = new Set<string>(placementsByTask[task.id]);
    for (const parentId of childToParents[task.id] ?? []) {
      for (const b of placementsByTask[parentId] ?? []) boardIds.add(b);
    }
    // No live placement (direct or inherited) → orphan (removed from pool /
    // board deleted) → hidden.
    if (boardIds.size === 0) return false;
    // Visible iff placed on at least one non-draft (active/completed) board.
    for (const id of boardIds) {
      if (boardStatusById[id] !== BoardStatus.DRAFT) return true;
    }
    return false;
  });
}
