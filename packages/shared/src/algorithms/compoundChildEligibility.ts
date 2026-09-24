/**
 * Compound child eligibility — may an EXISTING library task be linked as a
 * sub-task of a compound?
 *
 * The one guard shared by every path that links an existing task under a
 * compound: the Task Detail save (web `editCompoundStructure`, iOS
 * `applyTaskEditPatch`), which refuses with the message; the board wizard's
 * staged-edit apply, which skips an ineligible link silently; and the
 * sub-task picker, which disables ineligible rows with the message.
 *
 * Nested compounds ARE allowed (a child can be another compound — see
 * docs/TASK_SYSTEM.md); only a link that would close a loop is refused.
 * Hidden wizard drafts (`createdInWizard`) are excluded by the picker via
 * `computeBrowsableTasks`, not here.
 *
 * Swift twin: `CompoundChildEligibility.linkProblem` (identical strings,
 * identical check order).
 */
import { TaskType } from '../constants/enums';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import { isGoalLessCounter } from './browsableTasks';
import { findTransitiveParentCompounds } from './derivationPass';

/** The fields of a candidate task the guard reads. */
export type CompoundChildCandidate = Pick<
  Task,
  'id' | 'type' | 'isDeleted' | 'createdInWizard' | 'isCounter' | 'maxCount'
>;

/** The six user-facing refusal messages (byte-identical on iOS). */
export const COMPOUND_CHILD_LINK_MESSAGES = {
  self: 'A compound can’t contain itself.',
  duplicate: 'That task is already a sub-task here.',
  achievement: 'Achievements can’t be sub-tasks.',
  deleted: 'That task was deleted.',
  goalLessCounter: 'Counters without a goal can’t be sub-tasks.',
  loop: 'That would create a loop — it already contains this compound.',
} as const;

/**
 * Returns null when `candidate` may be linked under `parentId`, else the
 * user-facing reason. Checks run in this order: self, duplicate,
 * achievement, deleted, goal-less counter, loop — the first failing check
 * wins. The goal-less check mirrors the `isGoalLessCounter` write guard every
 * other compound-child write enforces (a hub counter with no goal can't
 * evaluate as a sub-task).
 *
 * @param parentId - The compound the candidate would be linked under.
 * @param candidate - The existing task being linked.
 * @param allLinks - Live links across ALL compounds (soft-deleted rows are
 *   ignored by the loop walk).
 * @param currentChildIds - The editor's current kept children (existing +
 *   already-picked).
 * @returns `null` if eligible, otherwise one of {@link COMPOUND_CHILD_LINK_MESSAGES}.
 */
export function compoundChildLinkProblem(
  parentId: string,
  candidate: CompoundChildCandidate,
  allLinks: readonly CompoundChild[],
  currentChildIds: ReadonlySet<string>,
): string | null {
  if (candidate.id === parentId) return COMPOUND_CHILD_LINK_MESSAGES.self;
  if (currentChildIds.has(candidate.id)) return COMPOUND_CHILD_LINK_MESSAGES.duplicate;
  if (candidate.type === TaskType.ACHIEVEMENT) return COMPOUND_CHILD_LINK_MESSAGES.achievement;
  if (candidate.isDeleted) return COMPOUND_CHILD_LINK_MESSAGES.deleted;
  if (isGoalLessCounter(candidate)) return COMPOUND_CHILD_LINK_MESSAGES.goalLessCounter;
  // A loop closes iff the candidate already (transitively) contains the parent.
  if (findTransitiveParentCompounds(parentId, [...allLinks]).has(candidate.id)) {
    return COMPOUND_CHILD_LINK_MESSAGES.loop;
  }
  return null;
}
