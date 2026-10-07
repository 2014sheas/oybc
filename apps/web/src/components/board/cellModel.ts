import { TaskType, formatCount, generateCounterTaskTitle, resolveCountKind, type CountKind, type Task } from '@oybc/shared';
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
    return generateCounterTaskTitle(task.action ?? '', task.maxCount ?? 0, task.unit ?? '', undefined, resolveCountKind(task));
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
  /**
   * The counter FAMILY's kind (`resolveFamilyCountKind` — a linked row
   * follows its root, R19). Absent → the task's own kind.
   */
  countKind?: CountKind;
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
    count: type === 'counting'
      ? { cur: input.currentCount ?? 0, max: task.maxCount ?? 0, kind: input.countKind ?? resolveCountKind(task) }
      : undefined,
    isFree: false,
    isLine: input.isLine ?? false,
    isShared: input.isShared || undefined,
    isArrived: input.isArrived || undefined,
    locked: input.locked || undefined,
    dirty: input.dirty || undefined,
  };
}

/** Width of one bar character: the bar's 9.5px head font × its average glyph advance. */
const BAR_CHAR_PX = 9.5 * 0.56;
/** Horizontal space the bar never gives its text: the cell's 8px insets + the bar's border/padding. */
const BAR_INSET_PX = 25;

/** A counting bar's text and which tier produced it. */
export interface CellCountFit {
  text: string;
  tier: 'full' | 'cur' | 'none';
}

/**
 * The counting bar's text tier (docs/COUNTER_KINDS.md §5): `cur/max`, else
 * `cur` (the ×tag already carries the goal), else nothing (fill only).
 * Deterministic from the known cell size — no measurement, no post-paint change.
 *
 * @param cur - The square's resolved count (minutes for duration).
 * @param max - The goal (minutes for duration).
 * @param kind - The counter family's kind.
 * @param cellSize - The cell's edge in px.
 * @returns The bar text and its tier.
 */
export function cellCountFit(cur: number, max: number, kind: CountKind, cellSize: number): CellCountFit {
  const room = (cellSize - BAR_INSET_PX) / BAR_CHAR_PX;
  const curText = formatCount(cur, kind);
  const full = `${curText}/${formatCount(max, kind)}`;
  if (full.length <= room) return { text: full, tier: 'full' };
  if (curText.length <= room) return { text: curText, tier: 'cur' };
  return { text: '', tier: 'none' };
}

/** The FREE center's view-model (gold star, not a real task). */
export function freeCellModel(key: string, label = 'FREE', locked = false): BoardCellModel {
  return { key, label, type: 'normal', done: true, isFree: true, isLine: false, locked: locked || undefined };
}
