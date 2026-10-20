import { db } from '../internal';
import { placementsReachedByTasks, type PlacementReach, type PlacementReachLookups } from '@oybc/shared';
import { fetchAllCompoundChildren } from './compoundChildren';
import { fetchAllBoardTasks } from './boardTasks';

/**
 * Read the three tables {@link placementsReachedByTasks} walks.
 *
 * @returns Every task, compound link and placement (tombstones included —
 *   the shared walk skips them).
 */
async function loadReachLookups(): Promise<PlacementReachLookups> {
  const [tasks, compoundChildren, boardTasks] = await Promise.all([
    db.tasks.toArray(),
    fetchAllCompoundChildren(),
    fetchAllBoardTasks(),
  ]);
  return { tasks, compoundChildren, boardTasks };
}

/**
 * The one placement reach (slice 2c): the given tasks, every live row linked
 * to them through `sharedCounterId`, their transitive parent compounds, and
 * every live placement of those. `taskIds` is the cascade input, `boardIds`
 * feeds sealed re-derive / watcher refresh.
 *
 * Runs inside the caller's ambient Dexie transaction (static imports only).
 *
 * @param taskIds - The tasks whose events or derived state changed.
 * @returns The shared {@link PlacementReach}.
 */
export async function loadPlacementReach(taskIds: Iterable<string>): Promise<PlacementReach> {
  return placementsReachedByTasks([...taskIds], await loadReachLookups());
}

/**
 * Each task's OWN reached boards — the {@link loadPlacementReach} walk run
 * per id (directly placed, or a sub-task of a placed compound at any depth),
 * with the tables read once for the whole set.
 *
 * Runs inside the caller's ambient Dexie transaction (or a plain read).
 *
 * @param taskIds - The tasks to resolve.
 * @returns Task id → the board ids its placements reach.
 */
export async function loadReachedBoardIdsByTask(
  taskIds: Iterable<string>,
): Promise<Map<string, ReadonlySet<string>>> {
  const ids = [...new Set(taskIds)];
  const out = new Map<string, ReadonlySet<string>>();
  if (ids.length === 0) return out;
  const lookups = await loadReachLookups();
  for (const id of ids) out.set(id, placementsReachedByTasks([id], lookups).boardIds);
  return out;
}

/**
 * The ids of every live (non-deleted) SEALED board, as stored now.
 *
 * @returns The sealed board ids.
 */
export async function loadLiveSealedBoardIds(): Promise<Set<string>> {
  const boards = await db.boards.toArray();
  return new Set(boards.filter((b) => !b.isDeleted && b.sealedAt != null).map((b) => b.id));
}

/**
 * The ids among `taskIds` whose placement reach includes a live SEALED board
 * — directly, or as a sub-task of a compound placed there at any depth. Such
 * a task is part of a closed board's permanent record: root → copy
 * propagation and the kind switch leave it untouched (issue #576 item 2).
 * Returns at once, without reading the reach tables, when nothing is sealed.
 *
 * @param taskIds - The candidates.
 * @returns The subset held by a sealed board.
 */
export async function taskIdsReachingSealedBoards(taskIds: Iterable<string>): Promise<Set<string>> {
  const ids = [...new Set(taskIds)];
  const out = new Set<string>();
  if (ids.length === 0) return out;
  const sealed = await loadLiveSealedBoardIds();
  if (sealed.size === 0) return out;
  for (const [id, boardIds] of await loadReachedBoardIdsByTask(ids)) {
    if ([...boardIds].some((b) => sealed.has(b))) out.add(id);
  }
  return out;
}
