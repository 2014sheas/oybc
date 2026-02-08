import { db } from '../database';
import type { Task, TaskStep, CreateTaskInput } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

/**
 * Task CRUD Operations
 */

/**
 * Fetch all tasks for a user (excluding deleted)
 */
export async function fetchTasks(userId: string): Promise<Task[]> {
  return db.tasks
    .where('[userId+isDeleted]')
    .equals([userId, false] as any)
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

    // Add steps if progress task
    if (input.type === 'progress' && input.steps) {
      for (let i = 0; i < input.steps.length; i++) {
        const stepInput = input.steps[i];
        const step: TaskStep = {
          id: generateUUID(),
          taskId: task.id,
          stepIndex: i,
          title: stepInput.title,
          type: stepInput.type,
          action: stepInput.action,
          unit: stepInput.unit,
          maxCount: stepInput.maxCount,
          createdAt: currentTimestamp(),
          updatedAt: currentTimestamp(),
          version: 1,
          isDeleted: false,
        };
        await db.taskSteps.add(step);
      }
    }
  });

  return task;
}

/**
 * Update a task
 */
export async function updateTask(
  id: string,
  updates: Partial<Task>
): Promise<void> {
  await db.tasks.update(id, {
    ...updates,
    updatedAt: currentTimestamp(),
    version: db.tasks.get(id).then((t) => (t?.version ?? 0) + 1),
  });
}

/**
 * Soft delete a task
 */
export async function deleteTask(id: string): Promise<void> {
  await db.tasks.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
  });
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
    type: stepInput.type as any,
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
 * Soft delete a task step
 */
export async function deleteTaskStep(id: string): Promise<void> {
  await db.taskSteps.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
  });
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
