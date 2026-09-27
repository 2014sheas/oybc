import { TaskType, generateCounterTaskTitle, type Task } from '@oybc/shared';
import type { BoardCellModel, CellType } from './RisoBoardCell';

/**
 * Visual cell type for a task — the one mapping every board renderer uses
 * (Board Edit redesign slice 1: the play surface, the edit draft, the
 * arrange slots and the wizard preview all used to carry their own copy).
 */
export function cellTypeOf(taskType: TaskType | string): CellType {
  if (taskType === TaskType.COUNTING) return 'counting';
  if (taskType === TaskType.COMPOUND) return 'compound';
  return 'normal';
}

/**
 * Display label for a task on a square: its title, or — for a counting task
 * with a blank title — the generated "Action N unit" name. Blank otherwise.
 * (The wizard preview used to read the raw title and showed an untitled
 * counter as an empty square.)
 */
export function taskCellLabel(task: Task): string {
  if (task.title && task.title.trim()) return task.title;
  if (task.type === TaskType.COUNTING) {
    return generateCounterTaskTitle(task.action ?? '', task.maxCount ?? 0, task.unit ?? '');
  }
  return '';
}

export interface TaskCellModelInput {
  /** Stable cell key — the placement id (or the task id pre-persist). */
  key: string;
  task: Task;
  /** Resolved completion for THIS square (windowed / sealed-aware). */
  done: boolean;
  /** Resolved counting progress for THIS square; ignored for non-counting tasks. */
  currentCount?: number;
  /** Part of a completed bingo line. */
  isLine?: boolean;
  isShared?: boolean;
  isArrived?: boolean;
  /** Per-square lock (`BoardTask.isLocked`). */
  locked?: boolean;
  /** Staged, unsaved edit on this square (edit mode only). */
  dirty?: boolean;
}

/**
 * Build a square's view-model from a task + its resolved state. Pure; the
 * caller resolves `done` / `currentCount` for its own context (live window,
 * sealed snapshot, staged draft, wizard preview) and this keeps label, type
 * and count shaping identical everywhere.
 */
export function toBoardCellModel(input: TaskCellModelInput): BoardCellModel {
  const { task } = input;
  const type = cellTypeOf(task.type);
  return {
    key: input.key,
    label: taskCellLabel(task),
    type,
    done: input.done,
    count: type === 'counting' ? { cur: input.currentCount ?? 0, max: task.maxCount ?? 0 } : undefined,
    isFree: false,
    isLine: input.isLine ?? false,
    isShared: input.isShared || undefined,
    isArrived: input.isArrived || undefined,
    locked: input.locked || undefined,
    dirty: input.dirty || undefined,
  };
}

/** The FREE center's view-model (gold star, not a real task). */
export function freeCellModel(key: string, label = 'FREE', locked = false): BoardCellModel {
  return { key, label, type: 'normal', done: true, isFree: true, isLine: false, locked: locked || undefined };
}
