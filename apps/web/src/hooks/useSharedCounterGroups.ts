import { useLiveQuery } from 'dexie-react-hooks';
import { buildSharedCounterGroups, isTaskExpired } from '@oybc/shared';
import type { SharedCounterGroup, Task } from '@oybc/shared';
import { db } from '../db/internal';
import { healBoardNames } from '../db/operations/boardNames';

/**
 * §Member rules (B3, RC9) — the task set a Counters surface shows.
 *
 * Per-window DERIVED counters carry their board window's `endDate`, so a
 * counter that has been on a few daily boards accumulates members that are
 * over. Hiding them by default is the Tasks tab's own rule, applied to the
 * same predicate (`isTaskExpired`).
 *
 * A ROOT — a task with no `sharedCounterId` — is never hidden, whatever its
 * own `endDate`: the root IS the counter, so dropping it would remove the
 * whole group from the hub rather than tidy one row out of it.
 *
 * Pure and exported so the rule can be unit-tested without rendering the
 * hook; `buildSharedCounterGroups` (vector-pinned) is never touched.
 *
 * @param tasks - Live, non-deleted tasks for the user.
 * @param showExpired - `true` returns `tasks` unchanged.
 * @param now - Reference time, injected for deterministic tests.
 * @returns The tasks to group.
 */
export function visibleCounterTasks(
  tasks: Task[],
  showExpired: boolean,
  now: Date = new Date(),
): Task[] {
  if (showExpired) return tasks;
  return tasks.filter((t) => t.sharedCounterId == null || !isTaskExpired(t, now));
}

/**
 * Live query hook: builds the SharedCounterGroup read-model for the
 * authenticated user's task graph. Reactively updates whenever tasks,
 * boards, or board-task placements change in Dexie.
 *
 * Uses `buildSharedCounterGroups` from `@oybc/shared` — the pure read
 * model over the existing shared-counter engine (Issue #84, Phases 0–4).
 * No new stored state is introduced; this is a view over live DB rows.
 *
 * §Member rules (B3, RC9) — per-window DERIVED counters expire with their
 * board's window, so by default a group only lists its LIVE members: the
 * task set is run through `isTaskExpired` before `buildSharedCounterGroups`
 * (which is vector-pinned and stays untouched). Two deliberate limits:
 * filtering happens BEFORE grouping, so an expired member can't contribute a
 * board row; and a ROOT — a task with no `sharedCounterId` — is NEVER hidden,
 * however old its own `endDate`, because dropping it would delete the whole
 * group from the hub rather than tidy one row out of it.
 *
 * @param userId - The authenticated user's id. Returns [] when undefined.
 * @param options.showExpired - `true` keeps expired members in. Defaults to
 *   `false` (the Tasks tab's default for the same predicate).
 * @returns Stable-sorted (by name) array of SharedCounterGroup view-models.
 *   Empty while loading, empty when the user has no shared counters.
 */
export function useSharedCounterGroups(
  userId: string | undefined,
  options: { showExpired?: boolean } = {},
): SharedCounterGroup[] {
  const showExpired = options.showExpired === true;
  return useLiveQuery(
    async () => {
      if (!userId) return [];

      // Fetch all non-deleted tasks + boards for this user. `buildSharedCounterGroups`
      // also filters isDeleted internally, but pre-filtering avoids pulling tombstones
      // through the grouping logic unnecessarily.
      const [allTasks, boards] = await Promise.all([
        db.tasks.filter((t) => t.userId === userId && !t.isDeleted).toArray(),
        db.boards
          .filter((b) => b.userId === userId && !b.isDeleted)
          .toArray()
          .then(healBoardNames),
      ]);

      const tasks = visibleCounterTasks(allTasks, showExpired);

      // Pull all boardTasks that link to any of the user's tasks, using the `taskId`
      // index from schema v7 (`anyOf` keeps this to one indexed range scan per chunk).
      const taskIds = tasks.map((t) => t.id);
      const boardTasks =
        taskIds.length > 0
          ? await db.boardTasks.where('taskId').anyOf(taskIds).filter((bt) => !bt.isDeleted).toArray()
          : [];

      return buildSharedCounterGroups({ tasks, boardTasks, boards });
    },
    [userId, showExpired],
    [] // default while loading
  );
}
