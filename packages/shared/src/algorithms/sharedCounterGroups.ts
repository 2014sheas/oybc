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
import type { TaskEvent } from '../types/taskEvent';
import { BoardStatus, TaskType, Timeframe } from '../constants/enums';
import { deriveDisplayedCount } from './sharedCounter';
import { formatTimeframeLabel } from './calendarBoundaries';
import { formatCounterName } from './counterName';
import { isWindowStampedDerived } from './memberRules';
import { resolveLinkedCounterDisplay } from './taskEvents';

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
  /** The task's window-scoped displayed amount: the ROOT's increment sum in
   *  the row's own window for a window-stamped derived row (when the caller
   *  supplies `eventsByTaskId`), else derived from the lifetime
   *  (`lifetime − baseline`). */
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
  /**
   * The counter's default log amount (R2 Counters UX refresh) — the source
   * task's `defaultLogAmount`, or `null` when never set (callers fall back
   * to `1`). Persisted per-counter via `setCounterDefaultLogAmount`; updated
   * to the most-recently-used log amount each time the user logs with a
   * different one.
   */
  defaultLogAmount: number | null;
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
  /**
   * Optional — non-deleted events grouped by `taskId` (at least the roots').
   * When present, a WINDOW-STAMPED derived member's `logged` is its root's
   * increment sum inside the row's own `[startDate, endDate]` (bounded at its
   * board's `sealedAt` when sealed) via `resolveLinkedCounterDisplay` — the
   * rule the play cell and the derivation kernel use, so the hub never reads
   * a later window's logs into an ended member. Absent → the lifetime
   * derivation, byte-identical to before.
   */
  eventsByTaskId?: Readonly<Record<string, TaskEvent[]>>;
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
    if (bt.taskId !== taskId || bt.isDeleted) continue;
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
 * The set of task ids that HEAD a shared-counter family.
 *
 * A root is either (a) a live task pointed at by some live task's
 * `sharedCounterId` — window-stamped derived counters and P5 linked members
 * alike — or (b) a P5 hub-born counter (`COUNTING` + `isCounter === true` +
 * no `sharedCounterId` of its own), which is a counter in its own right even
 * with zero members. This is exactly the root test
 * {@link buildSharedCounterGroups} runs, extracted so the library's row
 * renderers can ask "does this task head a family?" without rebuilding the
 * whole Counters-Hub view-model (owner ruling 2026-09-22: one generic family
 * row in the library, tapping through to the hub).
 *
 * Soft-deleted tasks are ignored on BOTH sides: a deleted member does not make
 * its target a root, and a deleted `isCounter` row is not one either.
 *
 * A link target counts only when it is actually PRESENT, live, and a COUNTING
 * task — the same predicate {@link buildSharedCounterGroups} applies when it
 * skips an orphaned group, so the two can never disagree. That matters twice
 * over: a dangling `sharedCounterId` (mid-sync, or a row an old client wrote)
 * must not conjure a family whose hub page would be empty, and it must not let
 * `computeBrowsableTasks` hide a member the hub would never show.
 *
 * Mirror of the iOS `SharedCounterGroups.swift` `sharedCounterRootIds(_:)`.
 *
 * @param tasks - Candidate tasks (soft-deleted rows are filtered internally).
 * @returns The root ids, in discovery order (link roots first, then hub-born).
 */
export function sharedCounterRootIds(tasks: Task[]): Set<string> {
  const live = tasks.filter((t) => !t.isDeleted);
  const liveById = new Map<string, Task>(live.map((t) => [t.id, t]));
  const roots = new Set<string>();
  for (const t of live) {
    if (t.sharedCounterId == null) continue;
    const root = liveById.get(t.sharedCounterId);
    if (root && root.type === TaskType.COUNTING) roots.add(t.sharedCounterId);
  }
  for (const t of live) {
    if (t.type === TaskType.COUNTING && t.isCounter === true && t.sharedCounterId == null) {
      roots.add(t.id);
    }
  }
  return roots;
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
  // `sharedCounterId`, PLUS the P5 hub-born counters (a COUNTING task flagged
  // `isCounter` is a counter in its own right, even with zero linked tasks) —
  // {@link sharedCounterRootIds}, which is the same walk this used to inline.
  // Seeding an empty linked list for a member-less root lets it flow through
  // the same member-view pipeline as a single-member group. A flagged row that
  // is itself derived (`sharedCounterId` set) is malformed — Zod rejects the
  // combination at create-input time, but synced rows are unguarded — and the
  // helper ignores it defensively.
  const linkedBySource = new Map<string, Task[]>();
  for (const rootId of sharedCounterRootIds(tasks)) linkedBySource.set(rootId, []);
  for (const t of tasks) {
    const src = t.sharedCounterId;
    if (src == null) continue;
    // A link whose target is missing / deleted / not a counter has no key —
    // the helper already applied this function's own orphan predicate, so the
    // `?.` drops exactly the members whose group the loop below would skip.
    linkedBySource.get(src)?.push(t);
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
      const board = pickPrimaryBoard(m.id, input.boardTasks, boardsById);
      // Window-stamped members read their own window from the root's events
      // (never `lifetime − baseline`, which counts later windows' logs too).
      const displayed =
        !isSource && input.eventsByTaskId && isWindowStampedDerived(m)
          ? resolveLinkedCounterDisplay(
              m,
              input.eventsByTaskId as Record<string, TaskEvent[]>,
              board?.sealedAt ?? null,
            ).displayed
          : deriveDisplayedCount({ baseline, maxCount: goal }, { currentCount: lifetime }).displayed;

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
      defaultLogAmount: source.defaultLogAmount ?? null,
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
