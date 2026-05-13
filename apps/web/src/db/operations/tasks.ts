import { db } from '../database';
import type {
  Task,
  TaskStep,
  CreateTaskInput,
  CreateCompoundTaskInput,
  CompoundChild,
} from '@oybc/shared';
import { AchievementTrigger, SyncOperationType, SyncStatus, TaskType, OperatorType } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * Task CRUD Operations
 */

/**
 * Fetch all tasks for a user (excluding deleted)
 */
export async function fetchTasks(userId: string): Promise<Task[]> {
  return db.tasks
    .filter((t) => t.userId === userId && !t.isDeleted)
    .sortBy('title');
}

/**
 * Fetch a single task by ID
 */
export async function fetchTask(id: string): Promise<Task | undefined> {
  return db.tasks.get(id);
}

/**
 * Create a new task.
 *
 * Phase 6.3 — Accepts `referencedBoardId` XOR `referencedTemplateId` for
 * ACHIEVEMENT tasks. Mutual-exclusion + XOR + type-match rules are enforced
 * by `CreateTaskInputSchema` upstream; the helper below also re-checks
 * defensively so a programmer error in a non-schema-validating call site
 * (e.g., a test) surfaces immediately.
 */
export async function createTask(
  userId: string,
  input: CreateTaskInput
): Promise<Task> {
  // Defensive guards mirroring the Zod refines on CreateTaskInputSchema —
  // upstream validation should have caught these, but a programmatic
  // call site (test, agent script) might skip Zod.
  if (input.referencedBoardId && input.referencedTemplateId) {
    throw new Error(
      'Task.referencedBoardId and referencedTemplateId are mutually exclusive',
    );
  }
  if (input.type === TaskType.ACHIEVEMENT) {
    if (!input.referencedBoardId && !input.referencedTemplateId) {
      throw new Error(
        'Achievement tasks must set exactly one of referencedBoardId or referencedTemplateId',
      );
    }
    // Recurring-template mode demands a positive requiredCount.
    // Specific-board mode ignores it.
    if (input.referencedTemplateId) {
      if (input.requiredCount === undefined || input.requiredCount <= 0) {
        throw new Error(
          'Achievement tasks in recurring-template mode require a positive requiredCount',
        );
      }
    } else if (input.requiredCount !== undefined) {
      throw new Error(
        'requiredCount is only meaningful in recurring-template mode',
      );
    }
  } else {
    if (input.referencedBoardId || input.referencedTemplateId) {
      throw new Error(
        'Only ACHIEVEMENT tasks may set referencedBoardId or referencedTemplateId',
      );
    }
    if (input.achievementTrigger !== undefined) {
      throw new Error(
        'Only ACHIEVEMENT tasks may set achievementTrigger',
      );
    }
    if (input.requiredCount !== undefined) {
      throw new Error(
        'Only ACHIEVEMENT tasks may set requiredCount',
      );
    }
  }

  const task: Task = {
    id: generateUUID(),
    userId,
    title: input.title,
    description: input.description,
    type: input.type,
    action: input.action,
    unit: input.unit,
    maxCount: input.maxCount,
    currentCount: input.type === TaskType.COUNTING ? 0 : undefined,
    referencedBoardId: input.referencedBoardId,
    referencedTemplateId: input.referencedTemplateId,
    // Default ACHIEVEMENT tasks to GREENLOG when the caller doesn't
    // specify — matches both the schema's defensive decode behavior
    // and derivation's read-time default.
    achievementTrigger:
      input.type === TaskType.ACHIEVEMENT
        ? input.achievementTrigger ?? AchievementTrigger.GREENLOG
        : undefined,
    requiredCount: input.requiredCount,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
  };

  // Post-unification: createTask is for primitives only (NORMAL / COUNTING /
  // ACHIEVEMENT). Compound tasks (which include former Progress as
  // `compound + isOrdered=true`) route through createCompound. The legacy
  // 'progress' string check is defensive — old call sites or remote
  // payloads that still emit type='progress' should surface here loudly
  // instead of silently writing an invalid Task row.
  if (input.type === TaskType.COMPOUND || (input.type as string) === 'progress') {
    throw new Error(
      `createTask received type='${input.type}'. Compound (and former progress) tasks must call createCompound (with isOrdered=true for progress).`
    );
  }

  await db.transaction('rw', [db.tasks], async () => {
    await db.tasks.add(task);
  });

  await addToSyncQueue('tasks', task.id, SyncOperationType.CREATE, task);

  return task;
}

/**
 * Create a new compound task (unifies former progress + composite create paths).
 *
 * Writes:
 *   - One `tasks` row with `type='compound'` + operator/threshold/isOrdered.
 *   - For each child entry: either references the provided `childTaskId`, or
 *     auto-creates a new primitive Task (if `autoCreate` is provided).
 *   - One `compoundChildren` row per child link.
 *
 * All writes run in a single Dexie transaction so partial failures don't
 * leave dangling rows. Sync entries are enqueued after the transaction
 * commits (matches the pattern in createTask).
 *
 * Caller is responsible for validating `input` against
 * `CreateCompoundTaskInputSchema` from @oybc/shared before calling.
 *
 * @param userId - The owning user's ID
 * @param input - Validated compound task creation input
 * @returns The newly created compound Task row
 */
export async function createCompound(
  userId: string,
  input: CreateCompoundTaskInput,
): Promise<Task> {
  const now = currentTimestamp();
  const compound: Task = {
    id: generateUUID(),
    userId,
    title: input.title,
    description: input.description,
    type: TaskType.COMPOUND,
    operator: input.operator,
    threshold: input.operator === OperatorType.M_OF_N ? input.threshold : undefined,
    isOrdered: input.isOrdered,
    isCompleted: false, // Field exists for column uniformity; never read on compound rows.
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };

  const childRowsToSync: { task?: Task; child: CompoundChild }[] = [];

  await db.transaction('rw', [db.tasks, db.compoundChildren], async () => {
    await db.tasks.add(compound);

    for (let i = 0; i < input.children.length; i++) {
      const entry = input.children[i];

      let childTaskId = entry.childTaskId;
      let inlineCreatedTask: Task | undefined;

      if (!childTaskId && entry.autoCreate) {
        // Inline-create a primitive child Task in the same transaction.
        inlineCreatedTask = {
          id: generateUUID(),
          userId,
          title: entry.autoCreate.title,
          description: entry.autoCreate.description,
          type: entry.autoCreate.type,
          action: entry.autoCreate.action,
          unit: entry.autoCreate.unit,
          maxCount: entry.autoCreate.maxCount,
          currentCount: entry.autoCreate.type === TaskType.COUNTING ? 0 : undefined,
          isCompleted: false,
          totalCompletions: 0,
          totalInstances: 0,
          createdAt: now,
          updatedAt: now,
          version: 1,
          isDeleted: false,
        };
        await db.tasks.add(inlineCreatedTask);
        childTaskId = inlineCreatedTask.id;
      }

      if (!childTaskId) {
        // Should be impossible given Zod validation, but defensive: skip
        // an entry that has neither childTaskId nor autoCreate.
        continue;
      }

      const childRow: CompoundChild = {
        id: generateUUID(),
        compoundTaskId: compound.id,
        childTaskId,
        childIndex: i,
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
      };
      await db.compoundChildren.add(childRow);
      childRowsToSync.push({ task: inlineCreatedTask, child: childRow });
    }
  });

  // Enqueue sync entries OUTSIDE the transaction (matches createTask pattern).
  await addToSyncQueue('tasks', compound.id, SyncOperationType.CREATE, compound);
  for (const { task: inlineTask, child: childRow } of childRowsToSync) {
    if (inlineTask) {
      await addToSyncQueue('tasks', inlineTask.id, SyncOperationType.CREATE, inlineTask);
    }
    await addToSyncQueue('compoundChildren', childRow.id, SyncOperationType.CREATE, childRow);
  }

  return compound;
}

/**
 * Update a task.
 *
 * Phase 6.3 — Pass the `null` sentinel as the patch value to explicitly
 * clear a reference field (Dexie treats `undefined` in a `Partial` as
 * "don't change", so a separate clear path is needed); `undefined`
 * leaves the existing value untouched.
 *
 * Defensive re-validation of the merged state happens here rather than
 * relying on `UpdateTaskInputSchema` alone — the schema's type-match
 * refines only fire when `type` is in the patch, but callers usually
 * omit it (type is immutable post-creation). To prevent a partial
 * update from sneaking an invalid shape into the local DB, we compute
 * the post-merge {type, refs} and re-check all three Phase 6.3 rules
 * before writing. The atomic update + sync-queue write keeps the local
 * DB consistent under a mid-write crash.
 */
export async function updateTask(
  id: string,
  updates: Partial<Task> & {
    referencedBoardId?: string | null;
    referencedTemplateId?: string | null;
    achievementTrigger?: AchievementTrigger | null;
    requiredCount?: number | null;
  },
): Promise<void> {
  const existing = await db.tasks.get(id);
  if (!existing) return;

  // `type` is immutable post-creation (the public `UpdateTaskInput`
  // type doesn't expose it). An internal `Partial<Task>`-typed caller
  // could still pass `updates.type` — reject loudly rather than
  // silently writing the change.
  if (updates.type !== undefined && updates.type !== existing.type) {
    throw new Error(
      `Task.type is immutable after creation (got '${updates.type}', existing '${existing.type}')`,
    );
  }

  // Resolve the post-patch values for the rules below.
  const nextType = existing.type;
  const nextRefBoard =
    updates.referencedBoardId === null
      ? undefined
      : updates.referencedBoardId ?? existing.referencedBoardId;
  const nextRefTpl =
    updates.referencedTemplateId === null
      ? undefined
      : updates.referencedTemplateId ?? existing.referencedTemplateId;
  const nextTrigger =
    updates.achievementTrigger === null
      ? undefined
      : updates.achievementTrigger ?? existing.achievementTrigger;
  const nextRequiredCount =
    updates.requiredCount === null
      ? undefined
      : updates.requiredCount ?? existing.requiredCount;

  // Rule 1: mutual exclusion.
  if (nextRefBoard && nextRefTpl) {
    throw new Error(
      'Task.referencedBoardId and referencedTemplateId are mutually exclusive',
    );
  }
  // Rule 2: ACHIEVEMENT tasks must keep exactly one reference.
  if (nextType === TaskType.ACHIEVEMENT && !nextRefBoard && !nextRefTpl) {
    throw new Error(
      'Achievement tasks must keep exactly one of referencedBoardId or referencedTemplateId',
    );
  }
  // Rule 3: non-ACHIEVEMENT tasks may not have references.
  if (nextType !== TaskType.ACHIEVEMENT && (nextRefBoard || nextRefTpl)) {
    throw new Error(
      'Only ACHIEVEMENT tasks may have referencedBoardId or referencedTemplateId',
    );
  }
  // Rule 4: trigger only on ACHIEVEMENT.
  if (nextType !== TaskType.ACHIEVEMENT && nextTrigger !== undefined) {
    throw new Error(
      'Only ACHIEVEMENT tasks may have achievementTrigger',
    );
  }
  // Rule 5: requiredCount required for template mode, forbidden otherwise.
  if (nextType === TaskType.ACHIEVEMENT && nextRefTpl) {
    if (nextRequiredCount === undefined || nextRequiredCount <= 0) {
      throw new Error(
        'Recurring-template ACHIEVEMENT tasks must keep a positive requiredCount',
      );
    }
  } else if (nextRequiredCount !== undefined) {
    throw new Error(
      'requiredCount is only meaningful for recurring-template ACHIEVEMENT tasks',
    );
  }

  const patch: Partial<Task> = {
    ...updates,
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  };
  // Translate `null` sentinel → `undefined` (Dexie stores absence).
  if (updates.referencedBoardId === null) patch.referencedBoardId = undefined;
  if (updates.referencedTemplateId === null) patch.referencedTemplateId = undefined;
  if (updates.achievementTrigger === null) patch.achievementTrigger = undefined;
  if (updates.requiredCount === null) patch.requiredCount = undefined;

  await db.transaction('rw', [db.tasks, db.syncQueue], async () => {
    await db.tasks.update(id, patch);
    const updated = await db.tasks.get(id);
    if (!updated) return;
    // Dev-mode short-circuit: skip syncing playground writes (mirrors the
    // pattern in updateAchievementSquareConfig from the pre-refactor
    // Phase 6.3 helper — see CLAUDE.md for the bypass-user convention).
    if (import.meta.env.DEV) {
      const playgroundUser = (updated as unknown as { userId?: string }).userId;
      if (playgroundUser === 'playground-user-1') return;
    }
    await db.syncQueue.add({
      id: generateUUID(),
      entityType: 'tasks',
      entityId: id,
      operationType: SyncOperationType.UPDATE,
      payload: JSON.stringify(updated),
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: currentTimestamp(),
      priority: 0,
    });
  });
}

/**
 * Soft delete a task.
 *
 * Increments `version` so LWW conflict resolution treats the deletion as
 * a later-wins operation against any concurrent update on another device.
 * A soft delete without a version bump could be overwritten by a stale
 * edit that happens to have a newer `updatedAt` timestamp.
 */
export async function deleteTask(id: string): Promise<void> {
  const existing = await db.tasks.get(id);
  if (!existing) return;
  await db.tasks.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });
  const task = await db.tasks.get(id);
  if (task) await addToSyncQueue('tasks', id, SyncOperationType.DELETE, task);
}

/**
 * Fetch task steps for a task
 */
export async function fetchTaskSteps(taskId: string): Promise<TaskStep[]> {
  return db.taskSteps
    .where('[taskId+stepIndex]')
    .between([taskId, 0], [taskId, Infinity])
    .filter((s) => !s.isDeleted)
    .toArray();
}

/**
 * Add a step to a progress task
 */
export async function addTaskStep(
  taskId: string,
  stepInput: {
    title: string;
    type: 'normal' | 'counting';
    action?: string;
    unit?: string;
    maxCount?: number;
    linkedTaskId?: string;
  }
): Promise<TaskStep> {
  // Get current max step index
  const steps = await fetchTaskSteps(taskId);
  const maxIndex = steps.length > 0 ? Math.max(...steps.map((s) => s.stepIndex)) : -1;

  const step: TaskStep = {
    id: generateUUID(),
    taskId,
    stepIndex: maxIndex + 1,
    title: stepInput.title,
    // `stepInput.type` is the narrower `'normal' | 'counting'` literal
    // union; cast through `TaskType` since TaskStep accepts the full enum.
    type: stepInput.type as TaskType,
    action: stepInput.action,
    unit: stepInput.unit,
    maxCount: stepInput.maxCount,
    linkedTaskId: stepInput.linkedTaskId,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
  };

  await db.taskSteps.add(step);
  return step;
}

/**
 * Atomically link a TaskStep to a standalone Task (via `linkedTaskId`),
 * bumping version + updatedAt and enqueueing the sync update. Runs in a
 * single transaction so the link and the sync-queue entry are consistent.
 *
 * @param stepId - ID of the TaskStep to update
 * @param linkedTaskId - ID of the standalone Task to link
 */
export async function linkTaskStep(stepId: string, linkedTaskId: string): Promise<void> {
  await db.transaction('rw', [db.taskSteps, db.syncQueue], async () => {
    const existing = await db.taskSteps.get(stepId);
    if (!existing) return;
    const updated = {
      ...existing,
      linkedTaskId,
      version: (existing.version ?? 0) + 1,
      updatedAt: currentTimestamp(),
    };
    await db.taskSteps.put(updated);
    await addToSyncQueue('taskSteps', stepId, SyncOperationType.UPDATE, updated);
  });
}

/**
 * Soft delete a task step.
 *
 * Increments `version` for LWW correctness and enqueues the delete so
 * peers learn about it. Previously neither was done, meaning a
 * concurrent edit on another device would silently resurrect the step.
 */
export async function deleteTaskStep(id: string): Promise<void> {
  const existing = await db.taskSteps.get(id);
  if (!existing) return;
  await db.taskSteps.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });
  const step = await db.taskSteps.get(id);
  if (step) await addToSyncQueue('taskSteps', id, SyncOperationType.DELETE, step);
}

/**
 * Find tasks that are linked to a step (for propagation)
 */
export async function findTasksByParentStep(stepId: string): Promise<Task[]> {
  return db.tasks
    .where('parentStepId')
    .equals(stepId)
    .filter((t) => !t.isDeleted)
    .toArray();
}
