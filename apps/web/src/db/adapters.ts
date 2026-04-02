import { TaskType, type Task, type TaskStep, type BoardTask } from '@oybc/shared';
import type { TaskSquareData, SquareState } from '../components/InteractiveTaskSquare';

/**
 * Converts a Task record (and its associated TaskStep records) to the
 * TaskSquareData shape expected by InteractiveTaskSquare.
 *
 * Steps are included for progress tasks so that `progressFraction` inside
 * InteractiveTaskSquare can compute the correct completion fraction using the
 * `completedStepIds` set derived from the BoardTask record.
 *
 * @param task - The Task record to adapt
 * @param taskSteps - All task steps; filtered internally by task ID
 * @returns TaskSquareData suitable for InteractiveTaskSquare
 */
export function taskToSquareData(task: Task, taskSteps: TaskStep[]): TaskSquareData {
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
 * Converts a BoardTask record to the SquareState shape expected by
 * InteractiveTaskSquare.
 *
 * @param bt - The BoardTask record to adapt
 * @returns SquareState with completedStepIds as a Set
 */
export function boardTaskToSquareState(bt: BoardTask): SquareState {
  return {
    isCompleted: bt.isCompleted,
    currentCount: bt.currentCount ?? 0,
    completedStepIds: new Set(bt.completedStepIds ?? []),
  };
}
