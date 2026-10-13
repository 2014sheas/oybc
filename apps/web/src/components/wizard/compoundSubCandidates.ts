import type { CompoundChild, Task } from '@oybc/shared';
import { subtaskQuickAddCandidates, type TaskEditPatch } from '../../db/taskEditPatch';
import { taskLookupValues, type TaskLookup } from '../counters/rowCounterTagName';
import { counterRootIdsIn, isSharedCounterRoot } from './quickAddCounterPlacement';

/** The compound editor's sub-task search set, with its counters split out. */
export interface CompoundSubCandidates {
  /** What the quick-add row searches: eligible tasks, then every counter. */
  candidates: Task[];
  /** The counters among them — a pick primes a NEW linked Counting sub-task. */
  counterIds: Set<string>;
}

/**
 * The compound editor's sub-task search set: the eligible library tasks
 * (`subtaskQuickAddCandidates`) with every shared counter root replaced by
 * the COUNTER — a search returns the counter, never its root task, and a pick
 * starts a new Counting sub-task linked to it (compound create's rule). iOS
 * twin: `QuickAddCounterPlacement.compoundSubCandidates`. The counter the
 * compound itself counts toward is left out (a sub linked to it would credit
 * it twice).
 *
 * @param parentId - The compound being edited.
 * @param libraryTasks - Browsable library tasks.
 * @param lookup - The surface's FULL task set (finds roots by their linked members).
 * @param allLinks - Live compound links (the loop check).
 * @param draft - The staged structure.
 */
export function compoundSubCandidates(
  parentId: string,
  libraryTasks: Task[],
  lookup: TaskLookup,
  allLinks: CompoundChild[],
  draft: TaskEditPatch,
): CompoundSubCandidates {
  const all = taskLookupValues(lookup);
  const rootIds = counterRootIdsIn(all);
  const countsToward = all.find((t) => t.id === parentId)?.countsTowardCounterId;
  const counters = libraryTasks.filter(
    (t) => !t.isDeleted && t.id !== countsToward && isSharedCounterRoot(t, rootIds),
  );
  const counterIds = new Set(counters.map((t) => t.id));
  const eligible = subtaskQuickAddCandidates(parentId, libraryTasks, allLinks, draft).filter(
    (t) => !counterIds.has(t.id) && t.id !== countsToward,
  );
  return { candidates: [...eligible, ...counters], counterIds };
}
