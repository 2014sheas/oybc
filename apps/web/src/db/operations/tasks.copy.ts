import { db } from '../database';
import type {
  Task,
  CreateTaskInput,
  CompoundChild,
} from '@oybc/shared';
import { AchievementTrigger, TaskType } from '@oybc/shared';
import { createTask, createCompound } from './tasks.crud';

// ─── Copy-from-source helpers ────────────────────────────────────────────────
//
// The wizard's `From a board…` filter long-press menu exposes
// `⎘ Add a copy of this task…`. The Copy modal collects per-type
// editable fields, pre-filled from the source. These helpers translate
// the (source, overrides) pair into the appropriate `createTask` /
// `createCompound` call so the Copy commit path goes through the same
// validation + sync-queue write as a brand-new task. See
// docs/ARCHITECTURE.md § "Wizard 'From a board' picker" for the
// product-level invariants (shallow compound copy; Achievement copies
// inherit the existing Phase 6.3 cycle-detection gate at wizard-commit
// time — copy itself is unguarded because the new Task has no
// placements yet and `hasCycle` would trivially return ok).
/**
 * Editable fields the Copy modal may override when copying a primitive
 * (NORMAL / COUNTING / ACHIEVEMENT) task. Any field left `undefined`
 * inherits from the source.
 *
 * For Achievement: if EITHER `referencedBoardId` or `referencedTemplateId`
 * is provided, BOTH override values are used as-is (treating the other's
 * `undefined` as "clear"). This is how the modal switches between
 * specific-board and recurring-template modes. If neither is provided,
 * both inherit from the source.
 */
export interface CopyTaskOverrides {
  title?: string;
  description?: string;
  // Counting overrides
  action?: string;
  unit?: string;
  maxCount?: number;
  // Achievement overrides
  achievementTrigger?: AchievementTrigger;
  referencedBoardId?: string;
  referencedTemplateId?: string;
  requiredCount?: number;
}
/**
 * Copy a primitive task (NORMAL / COUNTING / ACHIEVEMENT) under the
 * given user, applying the modal's overrides. Routes through the
 * existing `createTask`, so all schema refinements + sync writes
 * fire identically to a brand-new create.
 *
 * Throws if the source is a compound — call `copyCompound` for those.
 */
export async function copyTask(
  userId: string,
  source: Task,
  overrides: CopyTaskOverrides = {},
): Promise<Task> {
  if (source.type === TaskType.COMPOUND) {
    throw new Error(
      'copyTask cannot copy a compound source — use copyCompound instead',
    );
  }

  const input: CreateTaskInput = {
    title: overrides.title ?? source.title,
    description: overrides.description ?? source.description,
    type: source.type,
    timeframe: source.timeframe,
    startDate: source.startDate,
    endDate: source.endDate,
  };

  if (source.type === TaskType.COUNTING) {
    input.action = overrides.action ?? source.action;
    input.unit = overrides.unit ?? source.unit;
    input.maxCount = overrides.maxCount ?? source.maxCount;
  }

  if (source.type === TaskType.ACHIEVEMENT) {
    input.achievementTrigger =
      overrides.achievementTrigger ?? source.achievementTrigger;

    // If the modal touched either reference field, both come from
    // overrides (undefined-as-clear so a switch from board → template
    // doesn't leave both set and trip the XOR refinement).
    const overrodeRef =
      overrides.referencedBoardId !== undefined ||
      overrides.referencedTemplateId !== undefined;
    input.referencedBoardId = overrodeRef
      ? overrides.referencedBoardId
      : source.referencedBoardId;
    input.referencedTemplateId = overrodeRef
      ? overrides.referencedTemplateId
      : source.referencedTemplateId;

    input.requiredCount = overrides.requiredCount ?? source.requiredCount;
  }

  return createTask(userId, input);
}
/**
 * Copy a compound task. Shallow by default: the new compound parent
 * has a fresh id but its `compoundChildren` rows reference the SAME
 * primitive child Tasks the source had. This matches the unified
 * model where children are first-class Tasks with global completion —
 * deep-cloning would create a second set of independent counters,
 * which the brainstorm explicitly ruled out.
 *
 * Throws if the source is not a compound, or if the source's required
 * operator/isOrdered fields are missing (defensive: the schema enforces
 * them but a programmatic call site could in theory pass a malformed
 * source).
 */
export async function copyCompound(
  userId: string,
  source: Task,
  overrides: { title?: string; description?: string } = {},
): Promise<Task> {
  if (source.type !== TaskType.COMPOUND) {
    throw new Error('copyCompound requires a compound source task');
  }
  if (source.operator === undefined) {
    throw new Error('compound source missing operator field');
  }
  if (source.isOrdered === undefined) {
    throw new Error('compound source missing isOrdered field');
  }

  // Fetch live children, ordered. `compoundChildren` has no boolean
  // `isDeleted` index for the same IndexedDB reasons described in
  // the other Dexie helpers — JS filter is intentional.
  const sourceChildren = await db.compoundChildren
    .filter(
      (c: CompoundChild) => !c.isDeleted && c.compoundTaskId === source.id,
    )
    .toArray();
  sourceChildren.sort((a, b) => a.childIndex - b.childIndex);

  return createCompound(userId, {
    title: overrides.title ?? source.title,
    description: overrides.description ?? source.description,
    operator: source.operator,
    threshold: source.threshold,
    isOrdered: source.isOrdered,
    timeframe: source.timeframe,
    startDate: source.startDate,
    endDate: source.endDate,
    children: sourceChildren.map((c) => ({ childTaskId: c.childTaskId })),
  });
}
