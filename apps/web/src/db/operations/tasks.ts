import { db } from '../database';
import type { Task, TaskStep, CreateTaskInput } from '@oybc/shared';
import { SyncOperationType, TaskType } from '@oybc/shared';
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
