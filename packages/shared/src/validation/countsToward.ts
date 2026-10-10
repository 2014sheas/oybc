import { TaskType } from '../constants/enums';

/**
 * "Counts toward" row-shape rule (docs/SHARED_COUNTER_SETTINGS.md §3a, D7),
 * the `TaskSchema` refinement: a task may not count toward ITSELF, and a hub
 * counter (`isCounter`), a linked copy (`sharedCounterId` set) or an
 * Achievement may not count toward any counter. The cross-row rules (the
 * target is a live Discrete counter root; the task is not a root other rows
 * link to) need the database and live in `countsTowardProblem`, called at
 * write time.
 *
 * @param data - The task row (only the fields below are read).
 * @returns `true` when the row's shape is allowed.
 */
export function countsTowardShapeOk(data: {
  id?: string;
  type?: TaskType;
  isCounter?: boolean;
  sharedCounterId?: string | null;
  countsTowardCounterId?: string | null;
}): boolean {
  if (data.countsTowardCounterId == null) return true;
  if (data.countsTowardCounterId === data.id) return false;
  if (data.isCounter === true || data.sharedCounterId != null) return false;
  return data.type !== TaskType.ACHIEVEMENT;
}
