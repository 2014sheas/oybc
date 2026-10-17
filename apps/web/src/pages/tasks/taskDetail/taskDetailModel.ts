/**
 * Task Detail's pure half (docs/TASK_DETAIL_REDESIGN.md §A): the hero kicker,
 * the segments, the Boards rows and the Activity dots. No DB, no React — so
 * `useTaskDetail` stays a thin live-query shell and this is unit-testable.
 * iOS twin: `TaskDetailModel.swift`.
 */
import {
  AchievementTrigger, OperatorType, TaskType, boardDisplayName, compoundRuleLabel, formatCountTotal, formatTimeframeLabel,
  boardWindowEnd, isBoardActiveForList, isBoardEnded, isCoreBoard, resolveCountKind,
  type Board, type BoardTask, type CompoundChild, type Task, type TaskActivityKind,
} from '@oybc/shared';
import {
  placedTaskFor, taskToSquareData, taskToSquareState, buildSquareWindowContext,
} from '../../../db/adapters';
import type { TaskEvent } from '@oybc/shared';

export type DetailSegment = 'all' | 'boards' | 'links' | 'activity';

/** The pill segments, Boards carrying its placement count ("Boards · 2"). */
export function segmentOptions(boardCount: number): { value: DetailSegment; label: string }[] {
  return [
    { value: 'all', label: 'All' },
    { value: 'boards', label: boardCount > 0 ? `Boards · ${boardCount}` : 'Boards' },
    { value: 'links', label: 'Links' },
    { value: 'activity', label: 'Activity' },
  ];
}

/**
 * The hero kicker, derived from data: "COUNTING · LINKED COUNTER", "NORMAL ·
 * COUNTS TOWARD ‹COUNTER›", "COMPOUND · ALL OF 3", "ACHIEVEMENT · FIRST BINGO".
 *
 * @param task - The task.
 * @param counterName - The counter the task counts toward (Normal), if resolved.
 * @param childCount - Resolved compound sub-tasks.
 * @returns The uppercase kicker.
 */
export function heroKicker(task: Task, counterName: string | null, childCount: number): string {
  switch (task.type) {
    case TaskType.COUNTING: {
      if (task.sharedCounterId != null || task.isCounter) return 'COUNTING · LINKED COUNTER';
      const kind = resolveCountKind(task);
      return kind === 'discrete' ? 'COUNTING' : `COUNTING · ${kind.toUpperCase()}`;
    }
    case TaskType.COMPOUND:
      return `COMPOUND · ${compoundRuleLabel(task.operator as OperatorType | undefined, task.threshold, childCount).toUpperCase()}`;
    case TaskType.ACHIEVEMENT:
      return `ACHIEVEMENT · ${task.achievementTrigger === AchievementTrigger.BINGO ? 'FIRST BINGO' : 'GREENLOG'}`;
    default:
      return counterName ? `NORMAL · COUNTS TOWARD ${counterName.toUpperCase()}` : 'NORMAL';
  }
}

/** The hero band's tone class key. */
export function heroTone(task: Task): 'normal' | 'counting' | 'compound' | 'achievement' {
  return task.type === TaskType.COUNTING ? 'counting'
    : task.type === TaskType.COMPOUND ? 'compound'
      : task.type === TaskType.ACHIEVEMENT ? 'achievement' : 'normal';
}

/** One Boards-card row. */
export interface BoardRow {
  boardId: string;
  name: string;
  /** "CORE" badge text ("Core · weekly"), absent for a non-core board. */
  badge: string | null;
  /** "‹window› · ends ‹day› · ‹n› days left" (active) or "‹window› · expired" / "Draft". */
  caption: string;
  /** "12/20", "2/3", "Done" or null. */
  value: string | null;
  done: boolean;
  /** 0–1 progress for the ring. */
  fraction: number;
  draft: boolean;
  /** In play now (`isBoardActiveForList`). */
  active: boolean;
  /** Ended and not completed — an Activity "Missed" row. */
  missed: boolean;
  endDate: string | null;
}

const DAY_MS = 86_400_000;

/** "ends Sun · 2 days left" for an active dated board; "Last day" under 24h. */
function endsText(endDate: string | null | undefined, now: number): string | null {
  const end = endDate ? new Date(endDate).getTime() : NaN;
  if (Number.isNaN(end)) return null;
  const day = new Date(end).toLocaleDateString('en-US', { weekday: 'short' });
  if (end < now) return `ended ${day}`;
  const left = end - now < DAY_MS ? 'last day' : `${Math.ceil((end - now) / DAY_MS)} days left`;
  return `ends ${day} · ${left}`;
}

export interface BoardRowInput {
  task: Task;
  boards: ReadonlyArray<Board>;
  /** Live events for the task, its counter root and its sub-tasks (and their roots). */
  events: ReadonlyArray<TaskEvent>;
  taskMap: Record<string, Task>;
  childrenByCompound: Record<string, CompoundChild[]>;
  placements: ReadonlyArray<BoardTask>;
  now: Date;
}

/**
 * The task's state on each board it is placed on, read through the same
 * windowed resolvers board play uses (`taskToSquareState` over the board's own
 * window). PR 5 changes which placements feed this; the input is `placements`
 * + `boards` so that swap stays a one-line change in `useTaskDetail`.
 *
 * @returns Rows in the Boards tab's own order (the caller sorts).
 */
export function buildBoardRows(input: BoardRowInput): BoardRow[] {
  const { now } = input;
  const nowMs = now.getTime();
  return input.boards.map((board) => {
    // The same context board play builds (window end via `boardWindowEnd`, the seal bound), and the
    // placement-adjusted task (targetOverride / titleOverride), so a row reads exactly what the grid shows.
    const ctx = { ...buildSquareWindowContext([...input.events], board.startDate, boardWindowEnd(board)), sealedAt: board.sealedAt ?? null };
    const placement = input.placements.find((p) => p.boardId === board.id);
    const task = (placement && placedTaskFor(placement, input.taskMap)) ?? input.task;
    const links = input.childrenByCompound[task.id] ?? [];
    const sq = taskToSquareData(task, links, input.taskMap, input.childrenByCompound, ctx, placement?.childTargets);
    const state = taskToSquareState(task, links, input.taskMap, input.childrenByCompound, ctx, undefined, placement?.childTargets);
    const sealedDone = board.sealedAt != null && placement
      ? (board.sealedCompletedCells ?? []).includes(placement.row * board.boardSize + placement.col) : null;
    const done = sealedDone ?? state.isCompleted;
    let value: string | null = null;
    let fraction = done ? 1 : 0;
    if (sq.type === 'counting') {
      const kind = sq.countKind ?? resolveCountKind(task);
      value = `${formatCountTotal(state.currentCount, kind)}/${formatCountTotal(sq.maxCount ?? 0, kind)}`;
      fraction = (sq.maxCount ?? 0) > 0 ? Math.min(1, state.currentCount / (sq.maxCount ?? 1)) : 0;
    } else if (sq.type === 'compound' && sq.children && sq.children.length > 0) {
      const n = sq.children.filter((c) => c.isCompleted).length;
      value = `${n}/${sq.children.length}`;
      fraction = done ? 1 : n / sq.children.length;
    } else if (done) {
      value = 'Done';
    }
    const draft = board.status === 'draft';
    const active = !draft && isBoardActiveForList(board, now);
    const window = formatTimeframeLabel(board.timeframe, board.startDate, now);
    const ends = endsText(board.endDate, nowMs);
    const ended = !draft && isBoardEnded(board, nowMs);
    return {
      boardId: board.id,
      name: boardDisplayName(board),
      badge: isCoreBoard(board) ? `Core · ${board.timeframe}` : null,
      caption: draft ? 'Draft' : active ? [window, ends].filter(Boolean).join(' · ') : [window, board.sealedAt ? 'closed' : 'expired'].join(' · '),
      value, done, fraction, draft, active,
      // Only a task with something to miss: a Normal, a Counting with a goal, a Compound with sub-tasks.
      missed: ended && !done && (sq.type === 'normal' || (sq.type === 'counting' && (sq.maxCount ?? 0) > 0) || (sq.type === 'compound' && (sq.children?.length ?? 0) > 0)),
      endDate: board.endDate ?? null,
    };
  });
}

/** The Activity dot colour token per row kind (blue log / green completed / gold placed / red missed / paper created). */
export function activityDot(kind: TaskActivityKind): string {
  switch (kind) {
    case 'logged':
    case 'removed': return 'var(--riso-blue)';
    case 'completed': return 'var(--riso-green)';
    case 'placed': return 'var(--riso-gold)';
    case 'missed': return 'var(--riso-red)';
    default: return 'var(--riso-paper)';
  }
}

/** "Oct 12" for a recent-feeling short date. */
export function activityWhen(at: string): string {
  const t = Date.parse(at);
  return Number.isNaN(t) ? '' : new Date(t).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

/** "NOT DONE THIS WEEK" / "NOT DONE TODAY" / "… THIS MONTH" / "… THIS YEAR" from the anchor's timeframe; custom / indefinite: "NOT DONE". */
export function notDoneLabel(timeframe: string | undefined): string {
  switch (timeframe) {
    case 'daily': return 'NOT DONE TODAY';
    case 'weekly': return 'NOT DONE THIS WEEK';
    case 'monthly': return 'NOT DONE THIS MONTH';
    case 'yearly': return 'NOT DONE THIS YEAR';
    default: return 'NOT DONE';
  }
}

/** The Sub-tasks card heading: "Sub-tasks (3) · all of 3" / "any of 3" / "at least 2 of 3". */
export function subtasksHeading(task: Task, count: number): string {
  const rule = compoundRuleLabel(task.operator as OperatorType | undefined, task.threshold, count);
  const text = task.operator === OperatorType.M_OF_N ? `at least ${rule}` : rule.toLowerCase();
  return `Sub-tasks (${count}) · ${text}`;
}
