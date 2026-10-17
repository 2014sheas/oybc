/**
 * Task Detail + square interactions — the pure half (docs/TASK_DETAIL_REDESIGN.md).
 * The hero's anchor board, the compound "Complete next sub-task" pick and the
 * derived Activity feed. Swift twin: `apps/ios/OYBC/Helpers/TaskDetailKernel.swift`,
 * pinned by `tests/fixtures/taskDetailVectors.json`.
 */
import type { Board } from '../types/board';
import type { TaskEventKind } from '../types/taskEvent';
import { TaskType } from '../constants/enums';
import { compareBoardsForList, isBoardActiveForList } from './boardListSort';
import { formatCount, type CountKind } from './countValue';

/**
 * The board the Task Detail hero anchors its progress to: the soonest-ending
 * still-in-play board the task is placed on — the Boards tab's own order
 * (`compareBoardsForList`), board id as the final tie-break.
 *
 * @param boards - The boards the task is placed on (any status).
 * @param now - Reference time for the ended check.
 * @returns The anchor board, or `undefined` when none is in play.
 */
export function pickHeroAnchorBoard<B extends Board>(boards: ReadonlyArray<B>, now: Date = new Date()): B | undefined {
  return boards
    .filter((b) => !b.isDeleted && isBoardActiveForList(b, now))
    .sort((a, b) => compareBoardsForList(a, b, now) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))[0];
}

/** One compound child as the "next sub-task" pick sees it, in display order. */
export interface CompoundSubtaskCandidate {
  id: string;
  type: TaskType;
  isCompleted: boolean;
}

/** What "Complete next sub-task" does: toggle a child, or log on a counting one. */
export type CompoundSubtaskAction = { kind: 'toggle'; childId: string } | { kind: 'log'; childId: string };

/**
 * The hold menu's "Complete next sub-task": the first open child that can be
 * toggled (Normal or a nested Compound); when only counting children remain
 * open, a log on the first of them. Achievements are never actionable here.
 *
 * @param children - The compound's children in display order.
 * @returns The action, or `undefined` when nothing is open.
 */
export function nextCompoundSubtask(children: ReadonlyArray<CompoundSubtaskCandidate>): CompoundSubtaskAction | undefined {
  const open = children.filter((c) => !c.isCompleted);
  const toggle = open.find((c) => c.type === TaskType.NORMAL || c.type === TaskType.COMPOUND);
  if (toggle) return { kind: 'toggle', childId: toggle.id };
  const log = open.find((c) => c.type === TaskType.COUNTING);
  return log ? { kind: 'log', childId: log.id } : undefined;
}

/** The Activity row's kind — it picks the dot colour. */
export type TaskActivityKind = 'logged' | 'removed' | 'completed' | 'placed' | 'missed' | 'created';

/** One Activity row, newest first. */
export interface TaskActivityRow {
  key: string;
  kind: TaskActivityKind;
  /** ISO8601 — what the row sorts and dates by. */
  at: string;
  text: string;
}

/** Everything the Activity feed is derived from (no persisted log). */
export interface TaskActivityInput {
  task: { id: string; createdAt: string; unit?: string | null };
  /** The family kind (`resolveFamilyCountKind`) — formats log amounts. */
  kind: CountKind;
  events: ReadonlyArray<{
    id: string;
    kind: TaskEventKind;
    delta?: number;
    occurredAt: string;
    boardId?: string;
    isDeleted?: boolean;
  }>;
  placements: ReadonlyArray<{ id: string; boardId: string; createdAt: string; isDeleted?: boolean }>;
  /** Ended boards whose window the task did not complete. */
  missed: ReadonlyArray<{ boardId: string; endDate: string }>;
  /** Board id → display name (already healed via `boardDisplayName`). */
  boardNames: Readonly<Record<string, string>>;
}

/** The feed plus the footer's all-time completion count. */
export interface TaskActivity {
  rows: TaskActivityRow[];
  completionCount: number;
}

const KIND_ORDER: Record<TaskActivityKind, number> = {
  missed: 0, completed: 1, logged: 2, removed: 3, placed: 4, created: 5,
};

function amountText(value: number, kind: CountKind, unit: string | null | undefined): string {
  const u = kind === 'duration' || !unit ? '' : ` ${unit}`;
  return `${formatCount(value, kind)}${u}`;
}

function onBoard(boardId: string | undefined, names: Readonly<Record<string, string>>): string {
  const name = boardId ? names[boardId] : undefined;
  return name ? ` · ${name}` : '';
}

/**
 * The Activity tab's feed (docs/TASK_DETAIL_REDESIGN.md E5): logs, removals
 * and completions from the task's live events, one "Placed on" row per live
 * placement, one "Missed" row per ended board it did not complete, and
 * "Created". Newest first; equal instants order missed → completed → logged
 * → removed → placed → created, then by key.
 *
 * @param input - The task, its events, placements and missed boards.
 * @returns The rows and the all-time completion count.
 */
export function buildTaskActivity(input: TaskActivityInput): TaskActivity {
  const { task, kind, boardNames } = input;
  const rows: TaskActivityRow[] = [];
  let completionCount = 0;
  for (const e of input.events) {
    if (e.isDeleted) continue;
    if (e.kind === 'completion') {
      completionCount += 1;
      rows.push({ key: `e:${e.id}`, kind: 'completed', at: e.occurredAt, text: `Completed${onBoard(e.boardId, boardNames)}` });
    } else if (e.delta) {
      const removed = e.delta < 0;
      const text = removed
        ? `Removed ${amountText(-e.delta, kind, task.unit)}`
        : `Logged +${amountText(e.delta, kind, task.unit)}`;
      rows.push({ key: `e:${e.id}`, kind: removed ? 'removed' : 'logged', at: e.occurredAt, text: text + onBoard(e.boardId, boardNames) });
    }
  }
  for (const p of input.placements) {
    if (p.isDeleted) continue;
    const name = boardNames[p.boardId];
    if (name) rows.push({ key: `p:${p.id}`, kind: 'placed', at: p.createdAt, text: `Placed on ${name}` });
  }
  for (const m of input.missed) {
    const name = boardNames[m.boardId];
    if (name) rows.push({ key: `m:${m.boardId}`, kind: 'missed', at: m.endDate, text: `Missed · ${name}` });
  }
  rows.push({ key: `c:${task.id}`, kind: 'created', at: task.createdAt, text: 'Created' });
  rows.sort((a, b) => {
    const d = Date.parse(b.at) - Date.parse(a.at);
    if (d !== 0 && !Number.isNaN(d)) return d;
    return KIND_ORDER[a.kind] - KIND_ORDER[b.kind] || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
  });
  return { rows, completionCount };
}
