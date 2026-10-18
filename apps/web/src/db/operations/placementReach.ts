import { db } from '../internal';
import { placementsReachedByTasks, type PlacementReach } from '@oybc/shared';
import { fetchAllCompoundChildren } from './compoundChildren';
import { fetchAllBoardTasks } from './boardTasks';

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
  const ids = [...taskIds];
  const [tasks, compoundChildren, boardTasks] = await Promise.all([
    db.tasks.toArray(),
    fetchAllCompoundChildren(),
    fetchAllBoardTasks(),
  ]);
  return placementsReachedByTasks(ids, { tasks, compoundChildren, boardTasks });
}
