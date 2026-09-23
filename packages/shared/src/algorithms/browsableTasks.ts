import type { Task } from '../types/task';
import type { BoardTask } from '../types/boardTask';
import { BoardStatus, TaskType } from '../constants/enums';

/**
 * Filters the task library to the set that should appear in library-browse
 * surfaces (the Tasks tab list, the wizard "add from library" picker).
 *
 * Three independent classes of task are hidden:
 *
 * 1. Wizard-orphans — a task is HIDDEN iff it is wizard-born
 * (`createdInWizard === true`) AND it has no placement on a live, non-draft
 * board. Concretely, a wizard-born task is hidden when it lives ONLY on
 * draft boards, or has no live placement at all (removed from the wizard
 * pool — its Task row lingers after persist drops the `board_task` — or its
 * only board was deleted). Everything else is visible: standalone/copied
 * tasks (`createdInWizard` falsy) are never hidden, and a wizard-born task
 * with at least one active/completed placement is visible.
 *
 * 2. Goal-less counters (P5) — a COUNTING task with `isCounter === true` and
 * no `maxCount` cannot evaluate on a board; it lives in the Counters Hub,
 * not the library. See `isGoalLessCounter` for the exact predicate and why
 * it keys on the pair rather than bare absent-`maxCount`.
 *
 * 3. Shared-counter MEMBERS (owner ruling 2026-09-22) — a task whose
 * `sharedCounterId` points at a root that is PRESENT, live and COUNTING in
 * this same `tasks` set. That covers both the window-stamped derived counters
 * a board pull mints and the P5 linked members. The library shows ONE generic
 * row per counter family — the root — and the Counters Hub is the home for
 * the per-window rows; before this, every differing target count added
 * another near-identical "Read 5 pages" row beside its root. The root itself
 * is never hidden by this rule.
 *
 * The root-presence condition is exactly the orphan predicate
 * `buildSharedCounterGroups` (and so `sharedCounterRootIds`) applies, and it
 * must stay exactly that: a member is hidden here ONLY when the hub really
 * shows it under its family. A dangling `sharedCounterId` — mid-sync on a
 * fresh device, or a row an old client wrote — would otherwise be reachable
 * from nowhere at all.
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
 * @param boardTasks - all `board_task` placement rows (tombstoned rows are
 *   filtered internally — Board-integrity PR-1, docs/BOARD_INTEGRITY.md).
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
    if (bt.isDeleted) continue; // tombstoned placement → not a live placement
    if (!boardStatusById[bt.boardId]) continue; // deleted / absent board → ignore
    (placementsByTask[bt.taskId] ??= new Set<string>()).add(bt.boardId);
  }
  // Live id → task, for the member rule's root lookup below. Callers pass a
  // non-deleted set already; the `isDeleted` filter is belt-and-braces so this
  // can't disagree with the hub, which filters deleted rows itself.
  const liveById = new Map<string, Task>();
  for (const t of tasks) {
    if (!t.isDeleted) liveById.set(t.id, t);
  }
  return tasks.filter((task) => {
    if (isGoalLessCounter(task)) return false;
    // One generic family row: a member is represented by its root — but only
    // when that root really exists, so a dangling link stays visible here
    // rather than being reachable from nowhere.
    const root = task.sharedCounterId != null ? liveById.get(task.sharedCounterId) : undefined;
    if (root && root.type === TaskType.COUNTING) return false;
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

/**
 * P5 — Hub-born counters. A goal-less counter (COUNTING + `isCounter` +
 * no `maxCount`) cannot evaluate on a board; it lives in the Counters Hub,
 * not the library. Keyed on the PAIR — never bare absent-`maxCount` — so a
 * row whose flag was stripped by an old client degrades to a visible
 * library row, never an unreachable task (docs/SHARED_COUNTERS.md §P5
 * decision 5). Also used by the PR-2 compound-child write guards.
 */
export function isGoalLessCounter(
  task: Pick<Task, 'type' | 'isCounter' | 'maxCount'>,
): boolean {
  return (
    task.type === TaskType.COUNTING &&
    task.isCounter === true &&
    task.maxCount == null
  );
}
