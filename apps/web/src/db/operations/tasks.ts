import { db } from '../database';
import type {
  Task,
  TaskStep,
  CreateTaskInput,
  CreateCompoundTaskInput,
  CompoundChild,
} from '@oybc/shared';
import { SyncOperationType, TaskType, OperatorType } from '@oybc/shared';
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
 * Create a new task
 */
export async function createTask(
  userId: string,
  input: CreateTaskInput
): Promise<Task> {
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
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
  };

  await db.transaction('rw', [db.tasks, db.taskSteps], async () => {
    // Add task
    await db.tasks.add(task);

    // Add steps if progress task — each step also gets a standalone Task
    // record linked via linkedTaskId so steps are immediately pool-addable
    if (input.type === 'progress' && input.steps) {
      for (let i = 0; i < input.steps.length; i++) {
        const stepInput = input.steps[i];

        // Create standalone task for this step
        const stepTaskId = generateUUID();
        const now = currentTimestamp();
        const stepTask: Task = {
          id: stepTaskId,
          userId,
          title: stepInput.title,
          type: stepInput.type,
          action: stepInput.action,
          unit: stepInput.unit,
          maxCount: stepInput.maxCount,
          currentCount: stepInput.type === TaskType.COUNTING ? 0 : undefined,
          isCompleted: false,
          totalCompletions: 0,
          totalInstances: 0,
          createdAt: now,
          updatedAt: now,
          version: 1,
          isDeleted: false,
        };
        await db.tasks.add(stepTask);

        // Create the step record linked to both the parent and the standalone task
        const step: TaskStep = {
          id: generateUUID(),
          taskId: task.id,
          stepIndex: i,
          title: stepInput.title,
          type: stepInput.type,
          action: stepInput.action,
          unit: stepInput.unit,
          maxCount: stepInput.maxCount,
          linkedTaskId: stepTaskId,
          createdAt: now,
          updatedAt: now,
          version: 1,
          isDeleted: false,
        };
        await db.taskSteps.add(step);
      }
    }
  });

  void addToSyncQueue('tasks', task.id, SyncOperationType.CREATE, task);

  // Also sync any task steps and linked step tasks that were created
  const createdSteps = await db.taskSteps.where('taskId').equals(task.id).toArray();
  for (const step of createdSteps) {
    void addToSyncQueue('taskSteps', step.id, SyncOperationType.CREATE, step);
    if (step.linkedTaskId) {
      const linkedTask = await db.tasks.get(step.linkedTaskId);
      if (linkedTask) {
        void addToSyncQueue('tasks', linkedTask.id, SyncOperationType.CREATE, linkedTask);
      }
    }
  }

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
  void addToSyncQueue('tasks', compound.id, SyncOperationType.CREATE, compound);
  for (const { task: inlineTask, child: childRow } of childRowsToSync) {
    if (inlineTask) {
      void addToSyncQueue('tasks', inlineTask.id, SyncOperationType.CREATE, inlineTask);
    }
    void addToSyncQueue('compoundChildren', childRow.id, SyncOperationType.CREATE, childRow);
  }

  return compound;
}

/**
 * Update a task
 */
export async function updateTask(
  id: string,
  updates: Partial<Task>
): Promise<void> {
  const existing = await db.tasks.get(id);
  await db.tasks.update(id, {
    ...updates,
    updatedAt: currentTimestamp(),
    version: (existing?.version ?? 0) + 1,
  });
  const updated = await db.tasks.get(id);
  if (updated) void addToSyncQueue('tasks', id, SyncOperationType.UPDATE, updated);
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
  if (task) void addToSyncQueue('tasks', id, SyncOperationType.DELETE, task);
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
  if (step) void addToSyncQueue('taskSteps', id, SyncOperationType.DELETE, step);
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
