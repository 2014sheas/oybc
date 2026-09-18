/**
 * memberRules.ts — Board Sources "member rules" (docs/BOARD_SOURCES.md
 * §Member rules, B1).
 *
 * Pure arithmetic + planning for per-member rules on a pulled source: the
 * nominal window length of a timeframe, the pro-rated auto target when a
 * counting member crosses windows, the vary (dice) range and its seeded
 * roll, Split-up supply expansion, and the plan that decides — per selected
 * id — whether it is placed as-is or replaced by a window-stamped derived
 * counter / derived compound.
 *
 * Nothing here is wired into a write path yet: B1 ships the vocabulary and
 * the arithmetic, B2 persists the drafts these produce. No persistence, no
 * platform code, no side effects — the only non-determinism is the injected
 * `rng`, and the module is written so a seeded sequence reproduces exactly.
 *
 * Split out of `boardSources.ts` (rather than appended to it) to keep that
 * file under the 1000-line god-file guardrail; the public surface is the
 * `@oybc/shared` barrel either way.
 *
 * Has a Swift twin, pinned by the same vector fixture
 * (`tests/fixtures/memberRuleVectors.json`, copied byte-identically to
 * `apps/ios/OYBCTests/Fixtures/`). A change here is a change in two places.
 */

import { TaskType, Timeframe } from '../constants/enums';
import type {
  BoardSourceMemberRule,
  BoardSourcePartRule,
  VaryLevel,
} from '../types/boardSource';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import type { BoardSourceSupply } from './boardSources';
import { generateCounterTaskTitle } from './taskTitle';
import { uuidv5 } from './uuidv5';

/** uuidv5 name prefix for a per-window derived counter. */
export const DERIVED_TASK_NS = 'sources:derived';
/** uuidv5 name prefix for a per-window derived compound. */
export const DERIVED_COMPOUND_NS = 'sources:derived-compound';
/** uuidv5 name prefix for a derived compound's `compound_children` link. */
export const DERIVED_LINK_NS = 'sources:derived-link';

/**
 * Deterministic id of the derived counter for `rootTaskId` on `boardId`.
 *
 * @param boardId - The board the derived counter is stamped for.
 * @param rootTaskId - The shared-counter root (`sharedCounterId ?? id`).
 * @returns A stable uuidv5 — re-deriving the same window yields the same id.
 */
export function derivedTaskId(boardId: string, rootTaskId: string): string {
  return uuidv5(`${DERIVED_TASK_NS}:${boardId}:${rootTaskId}`);
}

/**
 * Deterministic id of the derived compound for `compoundId` on `boardId`.
 *
 * @param boardId - The board the derived compound is stamped for.
 * @param compoundId - The source compound task's id.
 * @returns A stable uuidv5.
 */
export function derivedCompoundId(boardId: string, compoundId: string): string {
  return uuidv5(`${DERIVED_COMPOUND_NS}:${boardId}:${compoundId}`);
}

/**
 * Deterministic id of the `compound_children` link from a derived compound to
 * one of its children (derived or original).
 *
 * @param derivedCompound - The derived compound's id (from {@link derivedCompoundId}).
 * @param childId - The child task id the link points at.
 * @returns A stable uuidv5.
 */
export function derivedLinkId(derivedCompound: string, childId: string): string {
  return uuidv5(`${DERIVED_LINK_NS}:${derivedCompound}:${childId}`);
}

/**
 * UTC day index of an ISO date's `YYYY-MM-DD` prefix.
 *
 * @param iso - An ISO8601 date or date-time string.
 * @returns Whole days since the epoch, or `null` if the prefix doesn't parse.
 */
function dayNumber(iso: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  if (!m) return null;
  return Math.floor(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])) / 86_400_000);
}

/**
 * Nominal length of a timeframe window in days. CUSTOM = inclusive calendar
 * span of the `YYYY-MM-DD` prefixes (UTC arithmetic — never local-time
 * subtraction, so a DST boundary inside the span can't shave or add a day);
 * INDEFINITE, or CUSTOM with a missing/unparseable bound, = `null`.
 *
 * @param timeframe - The window's timeframe.
 * @param startDate - CUSTOM only: the window's inclusive first day.
 * @param endDate - CUSTOM only: the window's inclusive last day.
 * @returns The nominal day count, or `null` when it is not knowable.
 */
export function nominalWindowDays(
  timeframe: Timeframe,
  startDate?: string | null,
  endDate?: string | null
): number | null {
  switch (timeframe) {
    case Timeframe.DAILY:
      return 1;
    case Timeframe.WEEKLY:
      return 7;
    case Timeframe.MONTHLY:
      return 30;
    case Timeframe.YEARLY:
      return 365;
    case Timeframe.CUSTOM: {
      if (!startDate || !endDate) return null;
      const a = dayNumber(startDate);
      const b = dayNumber(endDate);
      if (a === null || b === null) return null;
      return Math.max(1, b - a + 1);
    }
    default:
      return null;
  }
}

/**
 * Auto target for a counting member pulled from a board source onto a board
 * with a different window: the member's goal pro-rated by the window ratio,
 * rounded up, never above the goal itself (docs/BOARD_SOURCES.md §Target math).
 *
 * Four explicit branches in order: unknown source window, unknown target
 * window, a target window at least as long as the source's (no shrink), else
 * the pro-rated ceiling.
 *
 * @param goal - The member's own `maxCount` (integer ≥ 1).
 * @param sourceDays - Nominal days of the source board's window, or `null`.
 * @param targetDays - Nominal days of the board being assembled, or `null`.
 * @returns The auto target (integer ≥ 1, ≤ `goal`).
 */
export function autoTarget(goal: number, sourceDays: number | null, targetDays: number | null): number {
  if (sourceDays === null) return goal;
  if (targetDays === null) return goal;
  if (targetDays >= sourceDays) return goal;
  return Math.min(goal, Math.ceil((goal * targetDays) / sourceDays));
}

/** Vary level → the fraction of `t` the roll may move in either direction. */
const VARY_P: Record<VaryLevel, number> = { 0: 0, 1: 0.2, 2: 0.5 };

/**
 * Inclusive `[lo, hi]` a rolled target may land in. `t` is clamped to `1…goal`
 * first, `lo` never drops below 1, and `hi` never rises above `goal` — a vary
 * roll may soften a target but never asks for more than the member's own goal.
 *
 * @param t - The pre-vary target.
 * @param level - Vary level (0 = off).
 * @param goal - The member's own `maxCount`, the hard ceiling.
 * @returns The inclusive `[lo, hi]` pair.
 */
export function varyRange(t: number, level: VaryLevel, goal: number): [number, number] {
  const tc = Math.min(Math.max(1, t), goal);
  const p = VARY_P[level];
  return [Math.max(1, Math.round(tc * (1 - p))), Math.min(goal, Math.round(tc * (1 + p)))];
}

/**
 * Uniform whole-number roll inside {@link varyRange}. Level 0 never touches
 * `rng`, and neither does a degenerate range (`lo === hi`) — which is what
 * keeps a seeded sequence reproducible across platforms.
 *
 * @param t - The pre-vary target.
 * @param level - Vary level (0 = off).
 * @param goal - The member's own `maxCount`, the hard ceiling.
 * @param rng - Uniform `[0, 1)` source; consumed at most once.
 * @returns The rolled target (integer in `[lo, hi]`).
 */
export function rollTarget(t: number, level: VaryLevel, goal: number, rng: () => number): number {
  const [lo, hi] = varyRange(t, level, goal);
  if (level === 0 || lo === hi) return lo;
  return lo + Math.floor(rng() * (hi - lo + 1));
}

/** A {@link BoardSourceSupply} after Split-up expansion. */
export interface ExpandedSupply extends BoardSourceSupply {
  /** childTaskId → compound member id, for every id that entered via Split up. */
  partOf: Record<string, string>;
}

/**
 * Supply expansion (spec step 1): a member with `split: true` contributes its
 * non-excluded children instead of itself, in `childIndex` order.
 *
 * Stale-inert throughout — a rule for an id the supply doesn't carry, a part
 * rule for a child the compound no longer has, or `split` on a non-compound /
 * childless member all do nothing. The last-part guard means excluding every
 * part is treated as excluding none (a split member always contributes).
 *
 * @param supplies - Per-source supplies, already exclude-filtered by the caller.
 * @param childrenByCompoundId - Compound id → its `compound_children` rows.
 * @param tasksById - Id → task (only `id` and `type` are read).
 * @returns One {@link ExpandedSupply} per input supply, order preserved.
 */
export function applyMemberRules(
  supplies: BoardSourceSupply[],
  childrenByCompoundId: Record<string, Pick<CompoundChild, 'childTaskId' | 'childIndex'>[]>,
  tasksById: Record<string, Pick<Task, 'id' | 'type'>>
): ExpandedSupply[] {
  return supplies.map((supply) => {
    const rules = supply.source.memberRules ?? {};
    const out: string[] = [];
    const partOf: Record<string, string> = {};
    for (const id of supply.supplyTaskIds) {
      const rule = rules[id];
      const kids = childrenByCompoundId[id] ?? [];
      if (!rule?.split || tasksById[id]?.type !== TaskType.COMPOUND || kids.length === 0) {
        out.push(id);
        continue;
      }
      const ordered = [...kids].sort((a, b) => a.childIndex - b.childIndex).map((k) => k.childTaskId);
      const kept = ordered.filter((c) => !rule.parts?.[c]?.excluded);
      for (const c of kept.length > 0 ? kept : ordered) {
        out.push(c);
        partOf[c] = id;
      }
    }
    return { source: supply.source, supplyTaskIds: out, partOf };
  });
}

/** Which kind of board is being assembled — auto targets apply to `recurring` only. */
export type PlanMode = 'oneOff' | 'recurring';

/** The window a board (or a pulled source board) covers. */
export interface BoardWindow {
  timeframe: Timeframe;
  startDate: string | null;
  endDate: string | null;
}

/** The slice of `Task` {@link planDerivedTasks} reads. */
export type PlanTask = Pick<
  Task,
  'id' | 'type' | 'title' | 'action' | 'unit' | 'maxCount' | 'sharedCounterId' | 'startDate' | 'operator' | 'threshold'
>;

/** An in-memory window-stamped derived counter, before B2 persists it. */
export interface DerivedTaskDraft {
  id: string;
  /** The shared-counter root this derives from (`sharedCounterId ?? id`). */
  rootTaskId: string;
  /** The member id that produced it (may be another derived counter). */
  sourceMemberId: string;
  /** The selected id this draft stands in for on the board. */
  replacesId: string;
  maxCount: number;
  /** Event-derived lifetime count at mint time — a cache, never authored. */
  baseline: number;
  title: string;
  action: string;
  unit: string;
  timeframe: Timeframe;
  startDate: string | null;
  endDate: string | null;
}

/** One `compound_children` link of a {@link DerivedCompoundDraft}. */
export interface DerivedCompoundChildDraft {
  linkId: string;
  childTaskId: string;
  childIndex: number;
  /** True when `childTaskId` is a derived counter rather than the original child. */
  isDerived: boolean;
}

/** An in-memory derived compound (a One-square compound with re-targeted parts). */
export interface DerivedCompoundDraft {
  id: string;
  sourceCompoundId: string;
  replacesId: string;
  title: string;
  operator: Task['operator'];
  threshold: number | null;
  children: DerivedCompoundChildDraft[];
}

/** Inputs to {@link planDerivedTasks}. */
export interface PlanDerivedTasksArgs {
  /** The task ids picked for the board, in placement order. */
  selectedIds: string[];
  supplies: ExpandedSupply[];
  /** Hand-added ids — they win over any source copy. */
  manualTaskIds: string[];
  manualTaskVary: Record<string, VaryLevel>;
  boardId: string;
  window: BoardWindow;
  mode: PlanMode;
  tasksById: Record<string, PlanTask>;
  childrenByCompoundId: Record<string, Pick<CompoundChild, 'childTaskId' | 'childIndex'>[]>;
  /** Member id → the window of the source board that supplied it. */
  sourceWindowByMemberId: Record<string, BoardWindow | undefined>;
  /** Shared-counter root id → its event-derived lifetime count. */
  baselineByRootId: Record<string, number>;
  rng: () => number;
}

/** Output of {@link planDerivedTasks}. */
export interface PlanDerivedTasksResult {
  /** What actually lands in `board_tasks`, in `selectedIds` order. */
  placementIds: string[];
  derivedTasks: DerivedTaskDraft[];
  derivedCompounds: DerivedCompoundDraft[];
}

/** A member is already a window-stamped derived counter when it has both marks. */
function isWindowStampedDerived(t: PlanTask): boolean {
  return !!t.sharedCounterId && !!t.startDate;
}

/**
 * A counting task's own goal, or `null` when it is goal-less (an accumulator,
 * which has no target to pro-rate or vary).
 */
function goalOf(t: PlanTask): number | null {
  return typeof t.maxCount === 'number' && t.maxCount >= 1 ? Math.floor(t.maxCount) : null;
}

/**
 * Spec step 3 — decide, per selected id, whether it is placed as-is or
 * replaced by a window-stamped derived counter / derived compound.
 *
 * Pure and deterministic for a seeded `rng`: at most one sample per roll, taken
 * in `selectedIds` order (and within a compound, in `childIndex` order); a
 * level-0 or degenerate range takes none. Drafts are in-memory only — B2
 * materialises them before the `board_tasks` rows in one transaction.
 *
 * Precedence, in order: hand-added beats any source copy; among sources, the
 * FIRST supply that lists the id wins; a split part reads its part rule (the
 * parent's member-level `vary` is deliberately ignored in split mode); a
 * member-level `target` is honoured on board sources only.
 *
 * One deliberate simplification: if two selected members share a shared-counter
 * root, they collapse onto ONE derived counter (the first one's roll) — the
 * second member's roll has already consumed an rng sample before the dedupe is
 * seen. Counter-family exclusivity means the board shouldn't contain two
 * members of one family in the first place, so this is a belt-and-braces path.
 *
 * @param args - See {@link PlanDerivedTasksArgs}.
 * @returns Placement ids plus the derived drafts they refer to.
 */
export function planDerivedTasks(args: PlanDerivedTasksArgs): PlanDerivedTasksResult {
  const {
    selectedIds,
    supplies,
    manualTaskIds,
    manualTaskVary,
    boardId,
    window,
    mode,
    tasksById,
    childrenByCompoundId,
    sourceWindowByMemberId,
    baselineByRootId,
    rng,
  } = args;
  const manual = new Set(manualTaskIds);
  const targetDays = nominalWindowDays(window.timeframe, window.startDate, window.endDate);
  const placementIds: string[] = [];
  const derivedTasks: DerivedTaskDraft[] = [];
  const derivedCompounds: DerivedCompoundDraft[] = [];
  const derivedByRoot = new Map<string, DerivedTaskDraft>();

  const supplying = (id: string): ExpandedSupply | undefined =>
    supplies.find((s) => s.supplyTaskIds.includes(id));
  const sourceDaysFor = (memberId: string): number | null => {
    const w = sourceWindowByMemberId[memberId];
    return w ? nominalWindowDays(w.timeframe, w.startDate, w.endDate) : null;
  };
  const resolveTarget = (
    goal: number,
    explicit: number | undefined,
    fromBoard: boolean,
    memberIdForWindow: string
  ): number => {
    const base =
      explicit ??
      (fromBoard && mode === 'recurring'
        ? autoTarget(goal, sourceDaysFor(memberIdForWindow), targetDays)
        : goal);
    return Math.min(Math.max(1, Math.floor(base)), goal);
  };
  const mint = (t: PlanTask, replacesId: string, target: number, vary: VaryLevel): DerivedTaskDraft => {
    const goal = goalOf(t)!;
    const root = t.sharedCounterId ?? t.id;
    const maxCount = rollTarget(target, vary, goal, rng);
    const existing = derivedByRoot.get(root);
    if (existing) return existing; // same root twice on one board → one derived counter
    const action = t.action ?? '';
    const unit = t.unit ?? '';
    const d: DerivedTaskDraft = {
      id: derivedTaskId(boardId, root),
      rootTaskId: root,
      sourceMemberId: t.id,
      replacesId,
      maxCount,
      baseline: baselineByRootId[root] ?? 0,
      title: generateCounterTaskTitle(action, maxCount, unit, action ? undefined : t.title),
      action,
      unit,
      timeframe: window.timeframe,
      startDate: window.startDate,
      endDate: window.endDate,
    };
    derivedByRoot.set(root, d);
    derivedTasks.push(d);
    return d;
  };

  for (const id of selectedIds) {
    const t = tasksById[id];
    if (!t) {
      placementIds.push(id);
      continue;
    }
    const isManual = manual.has(id);
    const sup = isManual ? undefined : supplying(id);
    const fromBoard = sup?.source.kind === 'board';
    const rules = sup?.source.memberRules ?? {};
    const parentId = sup?.partOf[id];

    if (t.type === TaskType.COUNTING) {
      const goal = goalOf(t);
      if (goal === null) {
        placementIds.push(id);
        continue;
      }
      if (isManual) {
        const vary = manualTaskVary[id] ?? 0;
        // A member that is ALREADY window-stamped is re-minted for this window.
        if (isWindowStampedDerived(t)) {
          placementIds.push(mint(t, id, goal, vary).id);
          continue;
        }
        if (vary > 0) {
          placementIds.push(mint(t, id, goal, vary).id);
          continue;
        }
        placementIds.push(id);
        continue;
      }
      if (parentId) {
        // Split part — the part rule governs; the parent's `vary` is ignored.
        const part: BoardSourcePartRule = rules[parentId]?.parts?.[id] ?? {};
        const vary = part.vary ?? 0;
        if (fromBoard || part.target !== undefined || vary > 0) {
          placementIds.push(mint(t, id, resolveTarget(goal, part.target, fromBoard, id), vary).id);
          continue;
        }
        placementIds.push(id);
        continue;
      }
      const rule: BoardSourceMemberRule = rules[id] ?? {};
      const vary = rule.vary ?? 0;
      if (fromBoard) {
        placementIds.push(mint(t, id, resolveTarget(goal, rule.target, true, id), vary).id);
        continue;
      }
      if (vary > 0) {
        placementIds.push(mint(t, id, goal, vary).id);
        continue;
      }
      placementIds.push(id);
      continue;
    }

    if (t.type === TaskType.COMPOUND && sup && !rules[id]?.split) {
      const rule = rules[id];
      const kids = [...(childrenByCompoundId[id] ?? [])].sort((a, b) => a.childIndex - b.childIndex);
      if (!rule || kids.length === 0) {
        placementIds.push(id);
        continue;
      }
      const plans = kids.map((k) => {
        const c = tasksById[k.childTaskId];
        const goal = c ? goalOf(c) : null;
        if (!c || c.type !== TaskType.COUNTING || goal === null) return { k, c, derive: false as const };
        const part: BoardSourcePartRule = rule.parts?.[k.childTaskId] ?? {};
        const vary: VaryLevel = part.vary ?? rule.vary ?? 0;
        const hasTarget = part.target !== undefined || (fromBoard && (rule.vary ?? 0) > 0);
        if (!hasTarget && vary === 0) return { k, c, derive: false as const };
        return {
          k,
          c,
          derive: true as const,
          target: resolveTarget(goal, part.target, fromBoard, k.childTaskId),
          vary,
        };
      });
      if (!plans.some((p) => p.derive)) {
        placementIds.push(id);
        continue;
      }
      const cid = derivedCompoundId(boardId, id);
      const children: DerivedCompoundChildDraft[] = plans.map((p) => {
        const childTaskId = p.derive ? mint(p.c, p.k.childTaskId, p.target, p.vary).id : p.k.childTaskId;
        return {
          linkId: derivedLinkId(cid, childTaskId),
          childTaskId,
          childIndex: p.k.childIndex,
          isDerived: p.derive,
        };
      });
      derivedCompounds.push({
        id: cid,
        sourceCompoundId: id,
        replacesId: id,
        title: t.title,
        operator: t.operator,
        threshold: t.threshold ?? null,
        children,
      });
      placementIds.push(cid);
      continue;
    }

    placementIds.push(id);
  }
  return { placementIds, derivedTasks, derivedCompounds };
}
