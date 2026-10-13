import {
  countKindNeedsUnit,
  counterPickGoal,
  formatCountForInput,
  resolveCountKind,
  type CompoundChild,
  type PlacementBoard,
  type Task,
} from '@oybc/shared';
import { appendTypedChild, subtaskQuickAddCandidates, type TaskEditPatch } from '../../db/taskEditPatch';
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
 * twin: `QuickAddCounterPlacement.compoundSubCandidates`. Left out: the counter
 * the compound itself counts toward (a sub linked to it would credit it
 * twice) and every counter already a sub-task of THIS compound (other
 * compounds and the board are separate scopes).
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
  const used = countersInDraft(draft, all);
  // A counter is only ever offered AS the counter — never as a plain task.
  const isCounter = (t: Task): boolean => isSharedCounterRoot(t, rootIds);
  const counters = libraryTasks.filter(
    (t) => !t.isDeleted && t.id !== countsToward && !used.has(t.id) && isCounter(t),
  );
  const counterIds = new Set(counters.map((t) => t.id));
  const eligible = subtaskQuickAddCandidates(parentId, libraryTasks, allLinks, draft).filter(
    (t) => !isCounter(t) && t.id !== countsToward,
  );
  return { candidates: [...eligible, ...counters], counterIds };
}

/**
 * The counters already sub-tasks of this compound draft: a live child linked
 * to one (staged `sharedCounterId`, or a saved child whose task links to it),
 * or a root linked as itself.
 *
 * @param draft - The staged structure.
 * @param all - The full task set.
 */
export function countersInDraft(draft: TaskEditPatch, all: readonly Task[]): Set<string> {
  const byId = new Map(all.map((t) => [t.id, t]));
  const used = new Set<string>();
  for (const c of draft.children) {
    if (c.markedDeleted) continue;
    if (c.sharedCounterId) used.add(c.sharedCounterId);
    if (c.childTaskId) {
      used.add(c.childTaskId);
      const linked = byId.get(c.childTaskId)?.sharedCounterId;
      if (linked) used.add(linked);
    }
  }
  return used;
}

/**
 * Appends the linked Counting sub-task a picked counter becomes — one tap,
 * everything from the counter: its verb, noun, kind, the title through its
 * templates, and the goal at its default for `window` (`counterPickGoal`).
 * iOS twin: `RisoCompoundEditFieldsView.appendCounterSub`.
 *
 * @param draft - The staged structure.
 * @param root - The picked counter.
 * @param window - The host's window (none = Indefinite).
 */
export function appendCounterChild(draft: TaskEditPatch, root: Task, window?: PlacementBoard | null): TaskEditPatch {
  const kind = resolveCountKind(root);
  const goal = counterPickGoal(root, window);
  return appendTypedChild(
    draft,
    root.action ?? '',
    true,
    goal !== null ? formatCountForInput(goal, kind) : '',
    countKindNeedsUnit(kind) ? (root.unit ?? '') : '',
    kind,
    root,
  );
}
