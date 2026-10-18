/**
 * Task Detail's pure half (docs/TASK_DETAIL_REDESIGN.md §A): the hero kicker,
 * the segments, the Boards rows and the Activity dots. No DB, no React — so
 * `useTaskDetail` stays a thin live-query shell and this is unit-testable.
 * iOS twin: `TaskDetailModel.swift`.
 */
import {
  AchievementTrigger, OperatorType, TaskType, boardDisplayName, compoundRuleLabel, formatCountTotal, formatTimeframeLabel,
  isBoardActiveForList, isBoardEnded, isCoreBoard, resolveCountKind, resolveFamilyCountKind,
  type Board, type Task, type TaskActivityKind, type TaskPlacementRow,
} from '@oybc/shared';

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
  /** `taskPlacementRows` output — one per reached board. */
  rows: ReadonlyArray<TaskPlacementRow>;
  /** The reached boards, in display order (the caller sorts). */
  boards: ReadonlyArray<Board>;
  /** Workspace tasks — the rows' members and their counter roots. */
  taskById: Readonly<Record<string, Task>>;
  now: Date;
}

/**
 * The Boards rows, formatted from the kernel's per-board state
 * (`taskPlacementRows`: the placement reach, each board read through the
 * grid's own resolvers). A row may show a member reached THROUGH a compound
 * (a sub-task) or a counter root's linked row — its value is that member's.
 *
 * @returns One row per board that has a kernel row, in `boards` order.
 */
export function buildBoardRows(input: BoardRowInput): BoardRow[] {
  const { now } = input;
  const nowMs = now.getTime();
  const byBoard = new Map(input.rows.map((r) => [r.boardId, r]));
  return input.boards.flatMap((board) => {
    const r = byBoard.get(board.id);
    const member = r ? input.taskById[r.memberTaskId] : undefined;
    if (!r || !member) return [];
    let value: string | null = null;
    let fraction = r.done ? 1 : 0;
    if (r.count != null) {
      const kind = resolveFamilyCountKind(member, (id) => input.taskById[id]);
      const goal = r.goal ?? 0;
      value = `${formatCountTotal(r.count, kind)}/${formatCountTotal(goal, kind)}`;
      fraction = goal > 0 ? Math.min(1, r.count / goal) : 0;
    } else if (r.childrenTotal != null && r.childrenTotal > 0) {
      value = `${r.childrenDone ?? 0}/${r.childrenTotal}`;
      fraction = r.done ? 1 : (r.childrenDone ?? 0) / r.childrenTotal;
    } else if (r.done) {
      value = 'Done';
    }
    const draft = board.status === 'draft';
    const active = !draft && isBoardActiveForList(board, now);
    const window = formatTimeframeLabel(board.timeframe, board.startDate, now);
    const ends = endsText(board.endDate, nowMs);
    const ended = !draft && isBoardEnded(board, nowMs);
    // Only a member with something to miss: a Normal, a Counting with a goal, a Compound with sub-tasks.
    const missable = member.type === TaskType.NORMAL
      || (member.type === TaskType.COUNTING && (r.goal ?? 0) > 0)
      || (member.type === TaskType.COMPOUND && (r.childrenTotal ?? 0) > 0);
    return [{
      boardId: board.id,
      name: boardDisplayName(board),
      badge: isCoreBoard(board) ? `Core · ${board.timeframe}` : null,
      caption: draft ? 'Draft' : active ? [window, ends].filter(Boolean).join(' · ') : [window, board.sealedAt ? 'closed' : 'expired'].join(' · '),
      value, done: r.done, fraction, draft, active,
      missed: ended && !r.done && missable,
      endDate: board.endDate ?? null,
    }];
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
