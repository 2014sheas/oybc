import {
  TaskType,
  type Task,
  type TaskStep,
  type CompoundChild,
  evaluateCompound,
} from '@oybc/shared';
import type { TaskSquareData, SquareState } from '../components/interactiveTaskSquareUtils';

/**
 * Converts a Task record (and its associated TaskStep records) to the
 * TaskSquareData shape expected by InteractiveTaskSquare.
 *
 * For compound tasks, pass `compoundChildren` (the pre-resolved children for
 * this specific task) and `taskMap` so the children's completion states can be
 * evaluated.
 *
 * @param task - The Task record to adapt
 * @param taskSteps - All task steps; filtered internally by task ID (used for legacy progress rows)
 * @param compoundChildren - Compound tasks only: pre-resolved CompoundChild links for this task
 * @param taskMap - Compound tasks only: id → Task lookup for child resolution
 * @param childrenByCompound - Compound tasks only: full map used for recursive evaluateCompound
 * @returns TaskSquareData suitable for InteractiveTaskSquare
 */
export function taskToSquareData(
  task: Task,
  taskSteps: TaskStep[],
  compoundChildren?: CompoundChild[],
  taskMap?: Record<string, Task>,
  childrenByCompound?: Record<string, CompoundChild[]>,
): TaskSquareData {
  if (task.type === TaskType.COMPOUND) {
    const links = compoundChildren ?? [];
    const map = taskMap ?? {};
    const cbMap = childrenByCompound ?? {};
    const children = links.map((link) => {
      const childTask = map[link.childTaskId];
      if (!childTask) return { taskId: link.childTaskId, title: '<missing>', isCompleted: false };
      const isCompleted =
        childTask.type === TaskType.COMPOUND
          ? evaluateCompound(childTask, cbMap, map)
          : childTask.isCompleted;
      return { taskId: link.childTaskId, title: childTask.title, isCompleted };
    });

    return {
      id: task.id,
      title: task.title,
      type: 'compound',
      operator: task.operator ?? undefined,
      threshold: task.threshold ?? undefined,
      isOrdered: task.isOrdered ?? undefined,
      children,
    };
  }

  const type =
    task.type === TaskType.COUNTING
      ? 'counting'
      : task.type === TaskType.PROGRESS
        ? 'progress'
        : 'normal';

  const steps =
    task.type === TaskType.PROGRESS
      ? taskSteps
          .filter((s) => s.taskId === task.id)
          .sort((a, b) => a.stepIndex - b.stepIndex)
          .map((s) => ({ id: s.id, label: s.title }))
      : undefined;

  return {
    id: task.id,
    title: task.title,
    type,
    action: task.action ?? undefined,
    maxCount: task.maxCount ?? undefined,
    unit: task.unit ?? undefined,
    steps,
  };
}

/**
 * Derives the SquareState for a task square from the underlying Task record.
 *
 * Under the unified compound model, BoardTask is placement-only. Completion
 * state (isCompleted, currentCount) lives globally on Task. Progress-step
 * completion (completedStepIds) is no longer tracked per-board — returns an
 * empty Set for non-compound tasks.
 *
 * For compound tasks, pass `compoundChildren` and `taskMap` so the operator-
 * aware completion can be evaluated via `evaluateCompound`.
 *
 * @param task - The Task record whose state to adapt
 * @param compoundChildren - Compound tasks only: pre-resolved links for this task
 * @param taskMap - Compound tasks only: id → Task lookup
 * @param childrenByCompound - Compound tasks only: full map for recursive evaluation
 * @returns SquareState suitable for InteractiveTaskSquare
 */
export function taskToSquareState(
  task: Task,
  _compoundChildren?: CompoundChild[],
  taskMap?: Record<string, Task>,
  childrenByCompound?: Record<string, CompoundChild[]>,
): SquareState {
  if (task.type === TaskType.COMPOUND) {
    const cbMap = childrenByCompound ?? {};
    const map = taskMap ?? {};
    return {
      isCompleted: evaluateCompound(task, cbMap, map),
      currentCount: 0,
      completedStepIds: new Set<string>(),
    };
  }

  return {
    isCompleted: task.isCompleted,
    currentCount: task.currentCount ?? 0,
    // Per-board step completion is not tracked under the unified model.
    completedStepIds: new Set<string>(),
  };
}

/**
 * @deprecated Use `taskToSquareState` instead.
 * Kept for backward compatibility with callers outside the three Task 4.4
 * files; will be removed once playground files are migrated in Task 4.5.
 */
export const boardTaskToSquareState = taskToSquareState;
