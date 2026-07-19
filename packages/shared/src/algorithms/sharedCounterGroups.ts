/**
 * sharedCounterGroups.ts — Shared Counters read-model builder (P1).
 *
 * Groups the existing shared-counter task graph into "counter" view-models for
 * the Counters Hub and Counter Detail screens. This is a PURE read model over
 * data the shared-counter *engine* already maintains (Issue #84, Phases 0–4) —
 * it introduces no new stored state.
 *
 * A "counter" = one SOURCE counting task — either a task that at least one
 * other task links to via `sharedCounterId`, or (P5) a task explicitly
 * flagged `isCounter` so it renders as a single-member group even with zero
 * links — plus every task that links to it. The source task's `currentCount`
 * is the counter's running "lifetime" total; each member
 * task's displayed value is derived from that total via `deriveDisplayedCount`
 * (mirroring the live increment path).
 *
 * MVP scope (see docs/SHARED_COUNTERS.md):
 *  - `lifetime` = source task's `currentCount` (accepted as-is; not a separate
 *    never-reset accumulator — that is deferred with P4).
 *  - No sparkline / streak / best-window / closed-window history (P4).
 *  - Grouping is over EXISTING explicit `sharedCounterId` links only; no
 *    auto-grouping by action+unit.
 *
 * The math (`deriveDisplayedCount`) has a Swift twin in
 * `apps/ios/OYBC/Helpers/SharedCounter.swift`; the iOS Counters screens port
 * this grouping logic to Swift (`SharedCounterGroups.swift`). Keep them in sync.
 */

import type { Task } from '../types/task';
import type { Board } from '../types/board';
import type { BoardTask } from '../types/boardTask';
import { BoardStatus, TaskType, Timeframe } from '../constants/enums';
import { deriveDisplayedCount } from './sharedCounter';
import { formatTimeframeLabel } from './calendarBoundaries';
import { formatCounterName } from './counterName';

/**
 * One member task of a shared counter, resolved to its board placement +
 * window + progress, ready for a Hub/Detail row.
 */
export interface SharedCounterMemberTask {
  /** The member task's id. */
  taskId: string;
  /** The member task's display title. */
  taskTitle: string;
  /** True for the source task (the accumulator), false for a linked task. */
  isSource: boolean;
  /** The board this task is placed on (its "primary" non-deleted placement),
   *  or null when the task is on no live board. */
  boardId: string | null;
  boardName: string | null;
  /** The task's timeframe (for the accent dot color + window label). */
  timeframe: Timeframe | null;
  /** Human window label, e.g. "This week" → "Week of Mar 23 – 29, 2026",
   *  "February 2026", "2026". Null when no timeframe/date is known. */
  window: string | null;
  /** The task's personal target (`maxCount`), 0 when unset. */
  goal: number;
  /** The task's window-scoped displayed amount (= derived from the lifetime). */
  logged: number;
  /** `logged >= goal` (only when `goal > 0`). Over-achievement is real. */
  met: boolean;
  /** `logged - goal` when over the goal, else 0 (for the "N over" caption). */
  over: number;
  /** True when this task is "counting now" — its board is ACTIVE. Draft /
   *  completed / archived / placeless tasks are inactive ("Not counting now"). */
  isActive: boolean;
}

/**
 * A shared counter grouped for the Counters Hub / Detail.
 */
export interface SharedCounterGroup {
  /** Stable id = the source task's id. */
  counterId: string;
  /**
   * Display name — pair-derived via `formatCounterName(action, unit)` (R1),
   * falling back to the source task's stored `title` when the pair can't
   * produce one (e.g. a legacy row with neither field set).
   */
  name: string;
  /** Action verb (e.g. "Do") + unit (e.g. "reps") from the source task. */
  action: string | null;
  unit: string | null;
  /** All-time running total = the source task's `currentCount`. Never null. */
  lifetime: number;
  /** Source task first, then linked tasks (deterministic order). */
  tasks: SharedCounterMemberTask[];
  /** Total member tasks (source + linked). */
  taskCount: number;
  /** Distinct live boards the counter appears on. */
  boardCount: number;
  /** Member tasks that are counting now (active board). */
  activeTaskCount: number;
}

/** Inputs — pass the user's full non-deleted-inclusive sets; filtering is internal. */
export interface BuildSharedCounterGroupsInput {
  tasks: readonly Task[];
  boardTasks: readonly BoardTask[];
  boards: readonly Board[];
}

/**
 * Pick a member task's "primary" board placement: prefer an ACTIVE board, then
 * the most recent by startDate, then a stable id tie-break. Deterministic.
 */
function pickPrimaryBoard(
  taskId: string,
  boardTasks: readonly BoardTask[],
  boardsById: Map<string, Board>,
): Board | null {
  const candidates: Board[] = [];
  for (const bt of boardTasks) {
    if (bt.taskId !== taskId) continue;
    const board = boardsById.get(bt.boardId);
    if (board && !board.isDeleted) candidates.push(board);
  }
  if (candidates.length === 0) return null;
  candidates.sort((a, b) => {
    const aActive = a.status === BoardStatus.ACTIVE ? 0 : 1;
    const bActive = b.status === BoardStatus.ACTIVE ? 0 : 1;
    if (aActive !== bActive) return aActive - bActive;
    if (a.startDate !== b.startDate) return a.startDate < b.startDate ? 1 : -1; // newest first
    return a.id < b.id ? -1 : 1;
  });
  return candidates[0];
}

/**
 * Build the Counters-Hub / Counter-Detail view-models from the task graph.
 *
 * @returns One `SharedCounterGroup` per source counting task that has at least
 *   one live linked task OR is flagged `isCounter` (P5 hub-born counters),
 *   sorted by counter name (case-insensitive) for a stable display order.
 *   Empty array when the user has no shared counters.
 */
export function buildSharedCounterGroups(
  input: BuildSharedCounterGroupsInput,
): SharedCounterGroup[] {
  const tasks = input.tasks.filter((t) => !t.isDeleted);
  const tasksById = new Map<string, Task>(tasks.map((t) => [t.id, t]));
  const boardsById = new Map<string, Board>(input.boards.map((b) => [b.id, b]));

  // Source task ids = every task pointed at by a live linked task's
  // `sharedCounterId`. A source therefore always has >= 1 linked member.
  const linkedBySource = new Map<string, Task[]>();
  for (const t of tasks) {
    const src = t.sharedCounterId;
    if (src == null) continue;
    const list = linkedBySource.get(src);
    if (list) list.push(t);
    else linkedBySource.set(src, [t]);
  }

  // P5 — hub-born counters: a COUNTING task flagged `isCounter` is a counter
  // in its own right, even with zero linked tasks. Seed an empty linked list
  // for flagged sources the link walk didn't already discover, so they flow
  // through the same member-view pipeline as single-member groups. A flagged
  // row that is itself derived (`sharedCounterId` set) is malformed — Zod
  // rejects the combination at create-input time, but synced rows are unguarded — and is ignored defensively here.
  for (const t of tasks) {
    if (
      t.type === TaskType.COUNTING &&
      t.isCounter === true &&
      t.sharedCounterId == null &&
      !linkedBySource.has(t.id)
    ) {
      linkedBySource.set(t.id, []);
    }
  }

  const groups: SharedCounterGroup[] = [];

  for (const [sourceId, linked] of linkedBySource) {
    const source = tasksById.get(sourceId);
    // Skip orphaned groups: source deleted / missing / not a counting task.
    if (!source || source.type !== TaskType.COUNTING) continue;

    const lifetime = source.currentCount ?? 0;
    const members: Task[] = [source, ...linked];

    const boardIds = new Set<string>();
    let activeCount = 0;

    const memberViews: SharedCounterMemberTask[] = members.map((m) => {
      const isSource = m.id === sourceId;
      // The source is the accumulator (baseline 0); linked tasks derive.
      const baseline = isSource ? 0 : m.baseline ?? 0;
      const goal = m.maxCount ?? 0;
      const { displayed } = deriveDisplayedCount(
        { baseline, maxCount: goal },
        { currentCount: lifetime },
      );

      const board = pickPrimaryBoard(m.id, input.boardTasks, boardsById);
      if (board) boardIds.add(board.id);
      const isActive = board?.status === BoardStatus.ACTIVE;
      if (isActive) activeCount += 1;

      // Window from the task's own timeframe/date (falls back to its board's).
      const tf = m.timeframe ?? board?.timeframe ?? null;
      const startDate = m.startDate ?? board?.startDate ?? null;
      const window =
        tf && startDate ? formatTimeframeLabel(tf, startDate) : null;

      const met = goal > 0 && displayed >= goal;
      return {
        taskId: m.id,
        taskTitle: m.title,
        isSource,
        boardId: board?.id ?? null,
        boardName: board?.name ?? null,
        timeframe: tf,
        window,
        goal,
        logged: displayed,
        met,
        over: met ? displayed - goal : 0,
        isActive: isActive ?? false,
      };
    });

    // Deterministic member order: source first, then by board name, then id.
    memberViews.sort((a, b) => {
      if (a.isSource !== b.isSource) return a.isSource ? -1 : 1;
      const an = a.boardName ?? '';
      const bn = b.boardName ?? '';
      if (an !== bn) return an < bn ? -1 : 1;
      return a.taskId < b.taskId ? -1 : 1;
    });

    groups.push({
      counterId: sourceId,
      // R1: pair-derived display name (formatCounterName), stored-title
      // fallback when the (action, unit) pair can't produce one (e.g. a
      // legacy row with neither field set).
      name: formatCounterName(source.action, source.unit) || source.title,
      action: source.action ?? null,
      unit: source.unit ?? null,
      lifetime,
      tasks: memberViews,
      taskCount: memberViews.length,
      boardCount: boardIds.size,
      activeTaskCount: activeCount,
    });
  }

  groups.sort((a, b) =>
    a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }),
  );
  return groups;
}
