import { useLiveQuery } from 'dexie-react-hooks';
import { buildSharedCounterGroups } from '@oybc/shared';
import type { SharedCounterGroup, TaskEvent } from '@oybc/shared';
import { db } from '../db/internal';
import { healBoardNames } from '../db/operations/boardNames';

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
 * board's window, so by default a group only lists its LIVE members. The
 * rule lives in the kernel (`memberVisibility`), which applies it AFTER
 * root detection: the whole live task set goes in, so a board-born counter
 * whose members have all expired is still a root and still listed (the
 * pre-fix hook filtered the task set first and un-rooted it — see
 * `docs/BOARD_SOURCES.md` §Plan B3 hub expired filter). Mirrors iOS
 * `AppDatabase.fetchSharedCounterGroups`.
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
      const [tasks, boards] = await Promise.all([
        db.tasks.filter((t) => t.userId === userId && !t.isDeleted).toArray(),
        db.boards
          .filter((b) => b.userId === userId && !b.isDeleted)
          .toArray()
          .then(healBoardNames),
      ]);

      // Pull all boardTasks that link to any of the user's tasks, using the `taskId`
      // index from schema v7 (`anyOf` keeps this to one indexed range scan per chunk).
      const taskIds = tasks.map((t) => t.id);
      const boardTasks =
        taskIds.length > 0
          ? await db.boardTasks.where('taskId').anyOf(taskIds).filter((bt) => !bt.isDeleted).toArray()
          : [];

      // Window-stamped members read their root's in-window sum (the play
      // cell's and the kernel's rule — docs/WINDOWED_COMPLETION.md
      // §Derived-task carve-out, amended 2026-09-23), so the roots' events
      // ride along. Indexed on `taskId`; one range scan per chunk.
      const rootIds = [...new Set(tasks.flatMap((t) => (t.sharedCounterId ? [t.sharedCounterId] : [])))];
      const eventsByTaskId: Record<string, TaskEvent[]> = {};
      if (rootIds.length > 0) {
        for (const e of await db.taskEvents.where('taskId').anyOf(rootIds).toArray()) {
          if (!e.isDeleted) (eventsByTaskId[e.taskId] ??= []).push(e);
        }
      }

      return buildSharedCounterGroups({
        tasks,
        boardTasks,
        boards,
        eventsByTaskId,
        memberVisibility: { showExpired },
      });
    },
    [userId, showExpired],
    [] // default while loading
  );
}
