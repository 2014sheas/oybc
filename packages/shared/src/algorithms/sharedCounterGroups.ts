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
import type { CompoundChild } from '../types/compoundChild';
import { resolveLinkedCounterDisplay, withChildTarget, withPlacementParams } from './placementParams';
import { placementsReachedByRoot } from './derivationPass';
import type { Board } from '../types/board';
import type { BoardTask } from '../types/boardTask';
import type { TaskEvent } from '../types/taskEvent';
import { TaskType, Timeframe } from '../constants/enums';
import { quantizeCount, resolveCountKind, type CountKind } from './countValue';
import { deriveDisplayedCount } from './sharedCounter';
import { formatTimeframeLabel } from './calendarBoundaries';
import { counterDisplayName } from './counterSettings';
import { boardWindowEnd, boundWindowContextAtSeal, resolveTaskWindowState } from './taskEvents';
import { isTaskExpired } from './taskExpiry';
import { isBoardActiveForList, type InPlayBoardFields } from './boardListSort';

/**
 * One member task of a shared counter, resolved to its board placement +
 * window + progress, ready for a Hub/Detail row.
 */
export interface SharedCounterMemberTask {
  /** The placement this card stands for (slice 2b: members are placements). */
  boardTaskId: string;
  /** The member task on the card: the root, a linked task, or — when the
   *  placement is a parent compound — the linked CHILD reached through it. */
  taskId: string;
  /** The card's title: the placement's `titleOverride`, else the root's
   *  templates at the placement's goal, else the task's title. */
  taskTitle: string;
  /** True when the card's task is the root (the accumulator). */
  isSource: boolean;
  /** The host board. */
  boardId: string;
  boardName: string;
  /** The host board's timeframe (accent dot colour + window label). */
  timeframe: Timeframe | null;
  /** Human window label for the host board's window, e.g. "Week of Mar 23 – 29, 2026". */
  window: string | null;
  /** The placement's goal — `targetOverride` (converted to the task's kind),
   *  a parent compound placement's `childTargets` entry, else the task's own
   *  `maxCount` — 0 when unset. */
  goal: number;
  /** The in-window displayed amount (when the caller supplies
   *  `eventsByTaskId`): the ROOT's increment sum over the host board's window
   *  for a linked card, the root's OWN events for a root card — each bounded
   *  at a sealed board's `sealedAt`, the play cell's numbers. Without events,
   *  the lifetime arithmetic (`lifetime − baseline`). */
  logged: number;
  /** `logged >= goal` (only when `goal > 0`). Over-achievement is real. */
  met: boolean;
  /** `logged - goal` when over the goal, else 0 (for the "N over" caption). */
  over: number;
  /** True when this card is "counting now" — its board is still in play
   *  ({@link isBoardActiveForList}: ACTIVE, not closed, not past its endDate).
   *  Draft / completed / archived / closed / ended boards are inactive. */
  isActive: boolean;
  /** The parent compound placed here, when the card's task is a linked child
   *  reached through it; `null` for a direct placement. */
  viaCompoundId: string | null;
}

/**
 * A shared counter grouped for the Counters Hub / Detail.
 */
export interface SharedCounterGroup {
  /** Stable id = the source task's id. */
  counterId: string;
  /**
   * Display name — `counterDisplayName`: the root's `counterName`, else pair-derived via `formatCounterName(action, unit)` (R1),
   * falling back to the source task's stored `title` when the pair can't
   * produce one (e.g. a legacy row with neither field set).
   */
  name: string;
  /** Action verb (e.g. "Do") + unit (e.g. "reps") from the source task. */
  action: string | null;
  unit: string | null;
  /** The family's kind (the source's — D5). */
  countKind: CountKind;
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
  /** One card per placement — root cards first, then by board name, task, placement (deterministic). */
  tasks: SharedCounterMemberTask[];
  /** Distinct member tasks with a card. */
  taskCount: number;
  /** Distinct live boards the counter appears on. */
  boardCount: number;
  /** Distinct member tasks with a card that is counting now (active board). */
  activeTaskCount: number;
}

/** Inputs — pass the user's full non-deleted-inclusive sets; filtering is internal. */
export interface BuildSharedCounterGroupsInput {
  tasks: readonly Task[];
  boardTasks: readonly BoardTask[];
  boards: readonly Board[];
  /**
   * Optional — non-deleted events grouped by `taskId` (at least the roots').
   * When present, every PLACED member's `logged` is its in-window count —
   * a linked member's root increment sum over its own window (stamped) or
   * its board's (`resolveLinkedCounterDisplay`), a placed source's own events
   * over its board's window (`resolveTaskWindowState`), bounded at a sealed
   * board's `sealedAt` — the rule the play cell and the derivation kernel
   * use, so the hub never reads other windows' logs into a member. Absent →
   * the lifetime derivation, byte-identical to before.
   */
  eventsByTaskId?: Readonly<Record<string, TaskEvent[]>>;
  /**
   * Optional — which linked MEMBERS a group lists (§Member rules B3 RC9,
   * the Counters hub's "Show expired tasks" toggle). Per-window derived
   * counters carry their board window's `endDate`, so a counter that has
   * ridden a few boards accumulates members that are over; with
   * `showExpired: false` those are dropped from the group by the Tasks
   * tab's own predicate (`isTaskExpired(member, now)`).
   *
   * Applied AFTER root detection, never before it: a board-born counter is
   * a root only because a live task links to it, so filtering the task set
   * up front used to un-root a counter the moment its last member's window
   * closed and delete the whole group from the hub (the
   * hub-root-hidden-when-members-expire bug). A ROOT is never hidden,
   * whatever its own `endDate` — it IS the counter. A root whose members
   * have all expired is listed as a single-member group (lifetime total,
   * nothing counting now).
   *
   * Absent → every live member is listed (byte-identical to the
   * vector-pinned output).
   */
  memberVisibility?: SharedCounterMemberVisibility;
  /**
   * Compound links (any state; deleted rows ignored). A linked task placed
   * only through a parent compound gets a card per placement of that
   * compound (slice 2b), with the placement's `childTargets` goal. Absent →
   * no compound-reached cards.
   */
  compoundChildren?: ReadonlyArray<Pick<CompoundChild, 'compoundTaskId' | 'childTaskId' | 'isDeleted'>>;
}

/** See {@link BuildSharedCounterGroupsInput.memberVisibility}. */
export interface SharedCounterMemberVisibility {
  /** `true` lists expired members too — a linked task past its own stamp, and (slice 2b) any card whose host board's window has ended or closed. */
  showExpired: boolean;
  /** Reference time for `isTaskExpired` and for each member's "counting
   *  now" check; defaults to `new Date()` — inject it in tests. */
  now?: Date;
}

/**
 * Pick a member task's "primary" board placement: prefer a board still in play
 * ({@link isBoardActiveForList} — never the stored status, which stays ACTIVE
 * on an ended or closed board), then the most recent by startDate, then a
 * stable id tie-break. Deterministic.
 *
 * @param now - Reference time for the in-play check (defaults to the clock).
 */
export function pickPrimaryBoard<B extends Pick<Board, 'id' | 'isDeleted' | 'startDate'> & InPlayBoardFields>(
  taskId: string,
  boardTasks: ReadonlyArray<Pick<BoardTask, 'taskId' | 'boardId' | 'isDeleted'>>,
  boardsById: Map<string, B>,
  now: Date = new Date(),
): B | null {
  const candidates: B[] = [];
  for (const bt of boardTasks) {
    if (bt.taskId !== taskId || bt.isDeleted) continue;
    const board = boardsById.get(bt.boardId);
    if (board && !board.isDeleted) candidates.push(board);
  }
  if (candidates.length === 0) return null;
  candidates.sort((a, b) => {
    const aActive = isBoardActiveForList(a, now) ? 0 : 1;
    const bActive = isBoardActiveForList(b, now) ? 0 : 1;
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
 * @param boardTasks - Placements (any state); a live one with a `targetOverride` roots its task (rule c). Absent → rules a + b only.
 * @returns The root ids, in discovery order (link roots, hub-born, then override-rooted).
 */
export function sharedCounterRootIds(
  tasks: Task[],
  boardTasks?: ReadonlyArray<Pick<BoardTask, 'taskId' | 'isDeleted' | 'targetOverride'>>,
): Set<string> {
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
  // (c) Slice 2b: a plain counter with a live placement carrying a
  // `targetOverride` heads a family — the override is a per-board goal on
  // one counter, which is what a hub counter is. (Not "placed on more than
  // one board": that would make every recurring plain counter a hub counter.)
  for (const bt of boardTasks ?? []) {
    if (bt.isDeleted || bt.targetOverride == null) continue;
    const t = liveById.get(bt.taskId);
    if (t && t.type === TaskType.COUNTING && t.sharedCounterId == null) roots.add(t.id);
  }
  return roots;
}

/**
 * The member-row predicate {@link buildSharedCounterGroups} applies once the
 * roots are known: with `showExpired: false` a linked member whose window has
 * ended is left out of its group. Roots never pass through this (the source
 * row is always listed). Mirror of the Swift `isVisibleCounterMember`.
 */
function isVisibleCounterMember(
  member: Task,
  visibility: SharedCounterMemberVisibility | undefined,
): boolean {
  if (!visibility || visibility.showExpired) return true;
  return !isTaskExpired(member, visibility.now ?? new Date());
}

/**
 * Build the Counters-Hub / Counter-Detail view-models from the task graph.
 *
 * @returns One `SharedCounterGroup` per source counting task that has at least
 *   one live linked task OR is flagged `isCounter` (P5 hub-born counters),
 *   sorted by counter name (case-insensitive) for a stable display order.
 *   Empty array when the user has no shared counters. Root detection runs
 *   over EVERY live task; `input.memberVisibility` then decides which linked
 *   members each group lists (a root is never dropped).
 */
export function buildSharedCounterGroups(
  input: BuildSharedCounterGroupsInput,
): SharedCounterGroup[] {
  const tasks = input.tasks.filter((t) => !t.isDeleted);
  const tasksById = new Map<string, Task>(tasks.map((t) => [t.id, t]));
  const boardsById = new Map<string, Board>(input.boards.map((b) => [b.id, b]));
  const now = input.memberVisibility?.now ?? new Date();
  const livePlacements = input.boardTasks.filter((bt) => !bt.isDeleted);
  // A card IS a placement: the ONE reach (slice 2c) — the root's own
  // placements, its linked rows' placements and the placements of their
  // transitive parent compounds — shared with the cascade and the sealed
  // re-derive, so the hub can never list a square the kernel doesn't reach.
  const reachLookups = { tasks, compoundChildren: input.compoundChildren ?? [], boardTasks: livePlacements };

  // Source task ids = every task pointed at by a live linked task's
  // `sharedCounterId`, PLUS the P5 hub-born counters (a COUNTING task flagged
  // `isCounter` is a counter in its own right, even with zero linked tasks),
  // PLUS a plain counter placed with a `targetOverride` (slice 2b) —
  // {@link sharedCounterRootIds}. Seeding an empty linked list for a
  // member-less root lets it flow through the same card pipeline. A flagged
  // row that is itself derived (`sharedCounterId` set) is malformed — Zod
  // rejects the combination at create-input time, but synced rows are
  // unguarded — and the helper ignores it defensively.
  const linkedBySource = new Map<string, Task[]>();
  for (const rootId of sharedCounterRootIds(tasks, livePlacements)) linkedBySource.set(rootId, []);
  for (const t of tasks) {
    const src = t.sharedCounterId;
    if (src == null) continue;
    // A link whose target is missing / deleted / not a counter has no key —
    // the helper already applied this function's own orphan predicate, so the
    // `?.` drops exactly the members whose group the loop below would skip.
    // Expired members are dropped HERE — after the root walk above, which
    // saw them — so a root keeps its group when every member is over.
    if (!isVisibleCounterMember(t, input.memberVisibility)) continue;
    linkedBySource.get(src)?.push(t);
  }

  const groups: SharedCounterGroup[] = [];

  for (const [sourceId, linked] of linkedBySource) {
    const source = tasksById.get(sourceId);
    // Skip orphaned groups: source deleted / missing / not a counting task.
    if (!source || source.type !== TaskType.COUNTING) continue;

    const lifetime = quantizeCount(source.currentCount ?? 0);
    // The root is the title-settings source for its linked cards (web `placedTaskFor`).
    const settings = source;
    const linkedById = new Map<string, Task>(linked.map((t) => [t.id, t]));

    const boardIds = new Set<string>();
    const memberTaskIds = new Set<string>();
    const activeTaskIds = new Set<string>();
    /** `showExpired: false` also hides a card whose HOST window has ended or closed (a card is a placement). */
    const isExpiredPlacement = (board: Board): boolean => {
      if (!input.memberVisibility || input.memberVisibility.showExpired) return false;
      if (board.sealedAt) return true;
      const endMs = board.endDate ? new Date(board.endDate).getTime() : NaN;
      return !Number.isNaN(endMs) && endMs < now.getTime();
    };

    /** One card: the placement `bt` on `board`, standing for `task` (already placement-adjusted). */
    const card = (
      bt: BoardTask,
      board: Board,
      task: Task,
      kind: 'root' | 'linked' | 'child',
      viaCompoundId: string | null,
    ): SharedCounterMemberTask => {
      const isSource = kind === 'root';
      const goal = task.maxCount ?? 0;
      const hostWindow = { startDate: board.startDate, endDate: board.endDate ?? null };
      let displayed: number;
      if (isSource && input.eventsByTaskId) {
        // A PLACED root (a board-born counter's own square) is an
        // event-owning counting row: it reads its OWN events over its
        // board's window, sealed-bounded — the play cell's rule
        // (`resolveClosedBoardCounterDisplay` / the live window context) —
        // never the lifetime total, which is the group's `lifetime`.
        const ownEvents = input.eventsByTaskId[task.id] ?? [];
        // An absent / unparseable `sealedAt` applies no bound.
        const sealedAtMs = board.sealedAt ? new Date(board.sealedAt).getTime() : NaN;
        const events = Number.isNaN(sealedAtMs)
          ? ownEvents
          : boundWindowContextAtSeal({ [task.id]: ownEvents }, sealedAtMs).eventsByTaskId[task.id] ?? [];
        displayed = resolveTaskWindowState(task, events, board.startDate, boardWindowEnd(board)).count;
      } else if (!isSource && input.eventsByTaskId) {
        // Context window wins (slice 0): a placed linked task — stamped or
        // not, direct or through a parent compound — reads the host board's
        // window from the ROOT's events.
        displayed = resolveLinkedCounterDisplay(
          task,
          input.eventsByTaskId as Record<string, TaskEvent[]>,
          board.sealedAt ?? null,
          hostWindow,
        ).displayed;
      } else {
        // No events supplied: the library's lifetime arithmetic (source baseline 0).
        const baseline = isSource ? 0 : task.baseline ?? 0;
        displayed = deriveDisplayedCount({ baseline, maxCount: goal, countKind: task.countKind }, { currentCount: lifetime }).displayed;
      }

      boardIds.add(board.id);
      memberTaskIds.add(task.id);
      // "Counting now" is the Boards tab's in-play rule, not the stored
      // status — a board past its endDate (or closed) stays ACTIVE in the row.
      const isActive = isBoardActiveForList(board, now);
      if (isActive) activeTaskIds.add(task.id);
      const window = board.startDate ? formatTimeframeLabel(board.timeframe, board.startDate) : null;
      const met = goal > 0 && displayed >= goal;
      return {
        boardTaskId: bt.id,
        taskId: task.id,
        taskTitle: task.title,
        isSource,
        boardId: board.id,
        boardName: board.name,
        timeframe: board.timeframe ?? null,
        window,
        goal,
        logged: displayed,
        met,
        over: met ? quantizeCount(displayed - goal) : 0,
        isActive,
        viaCompoundId,
      };
    };

    const memberViews: SharedCounterMemberTask[] = [];
    for (const { boardTask: bt, memberTaskId, viaCompoundId } of placementsReachedByRoot(sourceId, reachLookups).placements) {
      const board = boardsById.get(bt.boardId);
      if (!board || board.isDeleted || isExpiredPlacement(board)) continue;
      if (memberTaskId === sourceId) {
        if (viaCompoundId !== null) continue; // a root is never a compound child
        memberViews.push(card(bt, board, withPlacementParams(source, bt, settings), 'root', null));
        continue;
      }
      // The reach lists every live linked row; the hub shows the visible ones.
      const linkedTask = linkedById.get(memberTaskId);
      if (!linkedTask) continue;
      if (viaCompoundId === null) {
        memberViews.push(card(bt, board, withPlacementParams(linkedTask, bt, settings), 'linked', null));
        continue;
      }
      // `childTargets` bind direct children only; a nested child keeps its own goal.
      memberViews.push(card(bt, board, withChildTarget(linkedTask, bt.childTargets), 'child', viaCompoundId));
    }

    // Deterministic card order: root cards first, then by board name, task id, placement id.
    memberViews.sort((a, b) => {
      if (a.isSource !== b.isSource) return a.isSource ? -1 : 1;
      const an = a.boardName ?? '';
      const bn = b.boardName ?? '';
      if (an !== bn) return an < bn ? -1 : 1;
      if (a.taskId !== b.taskId) return a.taskId < b.taskId ? -1 : 1;
      return a.boardTaskId < b.boardTaskId ? -1 : 1;
    });

    groups.push({
      counterId: sourceId,
      // The root's counterName, else R1 pair-derived (formatCounterName), stored-title
      // fallback when the (action, unit) pair can't produce one (e.g. a
      // legacy row with neither field set).
      name: counterDisplayName(source),
      action: source.action ?? null,
      unit: source.unit ?? null,
      countKind: resolveCountKind(source),
      lifetime,
      defaultLogAmount: source.defaultLogAmount ?? null,
      tasks: memberViews,
      taskCount: memberTaskIds.size,
      boardCount: boardIds.size,
      activeTaskCount: activeTaskIds.size,
    });
  }

  groups.sort((a, b) =>
    a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }),
  );
  return groups;
}
