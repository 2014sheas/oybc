/**
 * memberRules.ts — Board Sources "member rules" (docs/BOARD_SOURCES.md
 * §Member rules, B1 + B2).
 *
 * Pure arithmetic + planning for per-member rules on a pulled source: the
 * nominal window length of a timeframe, the pro-rated auto target when a
 * counting member crosses windows, the vary (dice) range and its seeded
 * roll, Split-up supply expansion, and the plan that decides — per selected
 * id — whether it is placed as-is or replaced by a window-stamped derived
 * counter / derived compound (B1), plus the window baseline those derived
 * counters start from and the complete `Task` / `CompoundChild` rows they
 * materialise into (B2).
 *
 * Nothing here is wired into a write path yet: this module produces rows,
 * the platform layers write them. No persistence, no platform code, no side
 * effects — the only non-determinism is the injected `rng`, and the module
 * is written so a seeded sequence reproduces exactly.
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
import type { TaskEvent } from '../types/taskEvent';
import type { BoardSourceSupply } from './boardSources';
import { deriveDisplayedCount } from './sharedCounter';
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
      // Total comparator — `childIndex`, then `childTaskId`. Duplicate indexes
      // exist in stored rows and Swift's `sorted` is NOT stable, so a tie left
      // to insertion order would expand in a different order on each platform.
      const ordered = [...kids]
        .sort(
          (a, b) =>
            a.childIndex - b.childIndex ||
            (a.childTaskId < b.childTaskId ? -1 : a.childTaskId > b.childTaskId ? 1 : 0)
        )
        .map((k) => k.childTaskId);
      const kept = ordered.filter((c) => !rule.parts?.[c]?.excluded);
      for (const c of kept.length > 0 ? kept : ordered) {
        out.push(c);
        partOf[c] = id;
      }
    }
    return { source: supply.source, supplyTaskIds: out, partOf };
  });
}

/**
 * Which kind of board is being assembled. Auto targets apply to BOTH kinds
 * (owner ruling 2026-09-21) — the mode only decides *when* a board-pulled
 * counting target is written, never how it is computed.
 */
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
  /**
   * The window this compound is stamped for — the same triple its derived
   * parts carry, copied from the board being assembled. B2's row builder
   * writes it onto the compound Task row, so the derived compound expires
   * with its window exactly like its parts do.
   */
  timeframe: Timeframe;
  startDate: string | null;
  endDate: string | null;
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
  /**
   * Whether the board being assembled is one-off or recurring.
   *
   * **No longer gates the target math** (owner ruling 2026-09-21: one-off
   * boards pro-rate too — docs/BOARD_SOURCES.md §Member rules). Kept on the
   * contract because every caller already has it and the vector fixture uses
   * it to pin that a board-sourced member resolves IDENTICALLY in both
   * modes; the one-off/recurring difference now lives entirely in WHEN the
   * target is written (a one-off pull prefills an explicit, pro-rated
   * `target`; a recurring board leaves it absent and auto-targets at each
   * spawn), not in how it is computed.
   */
  mode: PlanMode;
  tasksById: Record<string, PlanTask>;
  childrenByCompoundId: Record<string, Pick<CompoundChild, 'childTaskId' | 'childIndex'>[]>;
  /**
   * Task id → the window of the source board it came from. Keyed by every id
   * whose source window matters — supplied members AND the children of a
   * One-square compound (a compound's parts are pro-rated by looking up the
   * CHILD's id, never the compound's), so a caller that populates only the
   * supplied member ids silently gets `null` source days and no pro-rating.
   */
  sourceWindowByTaskId: Record<string, BoardWindow | undefined>;
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

/**
 * A member is already a window-stamped derived counter when it has both marks.
 *
 * Deliberately looser than the exported {@link isWindowStampedDerived}, which
 * also requires `createdInWizard`: a PLANNED member is re-minted for the new
 * window on the strength of the two marks alone (`PlanTask` doesn't carry the
 * provenance flag), while the exported predicate identifies a STORED row as
 * one of our per-window derived counters and wants all three.
 *
 * @param t - The member being planned.
 * @returns True when the member is itself a window-stamped derived counter.
 */
function isWindowStampedMember(t: PlanTask): boolean {
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
 * `target` — member-level OR part-level — is honoured on board sources only
 * (a pool member offers vary / split / part-exclusion and nothing else).
 *
 * No-identical-clone rule (owner ruling 2026-09-22): a board-sourced counting
 * member — or split part — whose RESOLVED target equals its own goal and whose
 * vary is off is placed as the root task itself rather than minted, because the
 * derived row would be an exact clone. Windowed Completion already evaluates
 * the root against the placing board's window. A later rule edit flips root →
 * derived at the next spawn, because every window re-plans from scratch.
 *
 * Collapse rule: two things that share a shared-counter root resolve to ONE
 * derived counter (the first one's roll). The dedupe is checked BEFORE the
 * roll, so a collapsed occurrence consumes no rng sample on either platform.
 * Two collapsed SELECTED members still both push that one derived id into
 * `placementIds`, so the same id can appear twice there — B2 must dedupe
 * before writing `board_tasks` (two rows for one task would trip the
 * placement-integrity / isCenter-uniqueness guards in docs/BOARD_INTEGRITY.md).
 * Two collapsed PARTS of one One-square compound are deduped here instead
 * (first in `childIndex` order wins, keeping its own `childIndex`/`linkId`),
 * because `derivedLinkId` is a pure function of `(compound, child)`: a repeated
 * `childTaskId` is the same `compound_children` primary key written twice, and
 * a compound whose `threshold` counts children would count one child twice.
 * Counter-family exclusivity constrains board *selection*, not compound
 * *authorship*, so the part case is ordinary user data while the member case
 * is belt-and-braces — the Swift twin mirrors both exactly.
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
    tasksById,
    childrenByCompoundId,
    sourceWindowByTaskId,
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
  const sourceDaysFor = (taskId: string): number | null => {
    const w = sourceWindowByTaskId[taskId];
    return w ? nominalWindowDays(w.timeframe, w.startDate, w.endDate) : null;
  };
  /**
   * The pre-vary target: an explicit rule if there is one, else the
   * window-pro-rated {@link autoTarget} for a BOARD-sourced member, else the
   * member's own goal. The gate is `fromBoard` alone — pool-sourced and
   * hand-added members never auto-target (they offer vary / split /
   * part-exclusion only), while a board-pulled member pro-rates on one-off
   * AND recurring boards alike (owner ruling 2026-09-21).
   *
   * The final `min(max(1, floor(base)), goal)` clamp is redundant for integer
   * targets (`varyRange` re-clamps `t` to `1…goal` identically) and is only
   * observable on a fractional explicit target, which Zod already forbids —
   * keep it anyway, and port it verbatim, so the two platforms can never
   * disagree about a malformed stored rule.
   */
  const resolveTarget = (
    goal: number,
    explicit: number | undefined,
    fromBoard: boolean,
    taskIdForWindow: string
  ): number => {
    const base =
      explicit ?? (fromBoard ? autoTarget(goal, sourceDaysFor(taskIdForWindow), targetDays) : goal);
    return Math.min(Math.max(1, Math.floor(base)), goal);
  };
  const mint = (t: PlanTask, replacesId: string, target: number, vary: VaryLevel): DerivedTaskDraft => {
    const goal = goalOf(t)!;
    const root = t.sharedCounterId ?? t.id;
    // The dedupe is checked BEFORE the roll: a collapsed occurrence consumes
    // no rng sample, so a seeded sequence reproduces identically on both
    // platforms regardless of how many members/parts share the root.
    const existing = derivedByRoot.get(root);
    if (existing) return existing; // same root twice on one board → one derived counter
    const maxCount = rollTarget(target, vary, goal, rng);
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
        if (isWindowStampedMember(t)) {
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
        // `target` — member- OR part-level — is honoured on board sources only;
        // a pool member offers vary / split / part-exclusion and nothing else.
        if (fromBoard || vary > 0) {
          const target = resolveTarget(goal, fromBoard ? part.target : undefined, fromBoard, id);
          // No identical clone (owner ruling 2026-09-22): a derived row exists
          // to carry a DIFFERENT target or a vary range. When the resolved
          // target already equals the part's own goal and vary is off, place
          // the root part itself, exactly as the pool / hand-added branches do.
          // Decided on `resolveTarget`'s RESULT, so the pro-rating stays intact.
          // `rollTarget` consumes no rng at level 0, so the skip cannot shift a
          // seeded sequence on either platform.
          if (target === goal && vary === 0) {
            placementIds.push(id);
            continue;
          }
          placementIds.push(mint(t, id, target, vary).id);
          continue;
        }
        placementIds.push(id);
        continue;
      }
      const rule: BoardSourceMemberRule = rules[id] ?? {};
      const vary = rule.vary ?? 0;
      if (fromBoard) {
        const target = resolveTarget(goal, rule.target, true, id);
        // No identical clone (owner ruling 2026-09-22) — see the split-part
        // branch above for the reasoning; same rule, same shape.
        if (target === goal && vary === 0) {
          placementIds.push(id);
          continue;
        }
        placementIds.push(mint(t, id, target, vary).id);
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
      // Total comparator, as in `applyMemberRules` — `childIndex` then
      // `childTaskId`, so a duplicate index can't roll in a different order
      // (and consume the seeded rng differently) on the two platforms.
      const kids = [...(childrenByCompoundId[id] ?? [])].sort(
        (a, b) =>
          a.childIndex - b.childIndex ||
          (a.childTaskId < b.childTaskId ? -1 : a.childTaskId > b.childTaskId ? 1 : 0)
      );
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
        // Board sources only, as in the split-part branch above.
        const hasTarget = fromBoard && (part.target !== undefined || (rule.vary ?? 0) > 0);
        if (!hasTarget && vary === 0) return { k, c, derive: false as const };
        return {
          k,
          c,
          derive: true as const,
          target: resolveTarget(goal, fromBoard ? part.target : undefined, fromBoard, k.childTaskId),
          vary,
        };
      });
      if (!plans.some((p) => p.derive)) {
        placementIds.push(id);
        continue;
      }
      const cid = derivedCompoundId(boardId, id);
      const children: DerivedCompoundChildDraft[] = [];
      const seenChildIds = new Set<string>();
      for (const p of plans) {
        const childTaskId = p.derive ? mint(p.c, p.k.childTaskId, p.target, p.vary).id : p.k.childTaskId;
        // Two parts that collapse onto one derived counter (same shared-counter
        // root) would otherwise emit the same `childTaskId` — and the same
        // `linkId` — twice. First in `childIndex` order wins, keeping its own
        // `childIndex` and `linkId`.
        if (seenChildIds.has(childTaskId)) continue;
        seenChildIds.add(childTaskId);
        children.push({
          linkId: derivedLinkId(cid, childTaskId),
          childTaskId,
          childIndex: p.k.childIndex,
          isDerived: p.derive,
        });
      }
      derivedCompounds.push({
        id: cid,
        sourceCompoundId: id,
        replacesId: id,
        title: t.title,
        operator: t.operator,
        threshold: t.threshold ?? null,
        timeframe: window.timeframe,
        startDate: window.startDate,
        endDate: window.endDate,
        children,
      });
      placementIds.push(cid);
      continue;
    }

    placementIds.push(id);
  }
  return { placementIds, derivedTasks, derivedCompounds };
}

// ── B2: baseline + row building ──────────────────────────────────────────────

/** The slice of a `TaskEvent` {@link computeWindowBaseline} reads. */
export type BaselineEvent = Pick<TaskEvent, 'taskId' | 'kind' | 'delta' | 'occurredAt' | 'isDeleted'>;

/**
 * The window baseline of a shared-counter root: the lifetime count the root
 * had reached when the window opened, so the derived counter's displayed
 * value (`root.currentCount − baseline`) starts this window at zero.
 *
 * Ruling RB2 — the sum of the `delta`s of the root's LIVE increment events
 * whose `occurredAt` is strictly BEFORE `boundary`, clamped at 0. Completion
 * events, tombstoned events and other tasks' events are ignored, and an event
 * exactly ON the boundary belongs to the new window, not to the baseline.
 *
 * Both sides are compared as INSTANTS (`Date.parse`), never as strings: board
 * dates are local ISO (`2026-09-18T00:00:00`, no offset) while events carry a
 * UTC stamp, so a lexical compare — or re-stamping a local date as UTC — would
 * move the boundary by the local offset and admit or drop every event either
 * side of local midnight. A stamp that doesn't parse (on either side) skips
 * the event rather than counting it.
 *
 * `boundary` is decided by the CALLER (the board's `startDate`, or the mint
 * `now` for an INDEFINITE / date-less board) — this helper never guesses it.
 * It must be a FULL timestamp (local ISO or offset-bearing); a date-only
 * string is not supported and parses inconsistently across platforms —
 * `Date.parse('2026-09-18')` is UTC midnight per the ES spec (date-only forms
 * are UTC, date-TIME forms without an offset are local), while the iOS twin's
 * ISO parser has no date-only format at all and would return 0 instead.
 *
 * @param rootTaskId - The shared-counter root whose events are summed.
 * @param events - Candidate events; any task's, any kind, live or tombstoned.
 * @param boundary - ISO8601 instant the window opens at.
 * @returns The baseline count (integer ≥ 0).
 */
export function computeWindowBaseline(
  rootTaskId: string,
  events: BaselineEvent[],
  boundary: string
): number {
  const b = Date.parse(boundary);
  if (Number.isNaN(b)) return 0;
  let sum = 0;
  for (const e of events) {
    if (e.isDeleted || e.taskId !== rootTaskId || e.kind !== 'increment') continue;
    if (typeof e.delta !== 'number' || !Number.isFinite(e.delta)) continue;
    const t = Date.parse(e.occurredAt);
    if (Number.isNaN(t) || !(t < b)) continue;
    sum += e.delta;
  }
  return Math.max(0, sum);
}

/**
 * Is this STORED task row one of our per-window derived counters?
 *
 * All three marks together — a shared-counter link, a window start, and the
 * wizard-born provenance flag. Each alone is ordinary user data: a hand-made
 * linked counter has the first, a timeboxed task the second, a wizard-born
 * task the third. Only the three together identify a row this pipeline minted
 * for one window (and may therefore refresh or retire when that window is
 * re-derived).
 *
 * @param t - The task row to test.
 * @returns True when the row is a window-stamped derived counter.
 */
export function isWindowStampedDerived(
  t: Pick<Task, 'sharedCounterId' | 'startDate' | 'createdInWizard'>
): boolean {
  return !!t.sharedCounterId && !!t.startDate && t.createdInWizard === true;
}

/**
 * Inputs to {@link buildDerivedRows}.
 *
 * Two invariants the CALLER owes, because the builder degrades quietly rather
 * than throwing: every `rootTaskId` in `drafts.derivedTasks` must be present in
 * `rootsById` (a missing root mirrors a count of 0, writing a row that
 * contradicts its own root until the next increment heals it), and every
 * `sourceCompoundId` in `drafts.derivedCompounds` must be present in
 * `compoundsById` — and the draft it belongs to must carry an `operator`, since
 * a compound row without one is a row `TaskSchema` rejects.
 */
export interface DerivedRowsInput {
  /** The drafts to materialise, straight out of {@link planDerivedTasks}. */
  drafts: PlanDerivedTasksResult;
  userId: string;
  /** ISO8601 mint time — every row's `createdAt` / `updatedAt`. */
  now: string;
  /** Shared-counter root id → the root row (its `currentCount` is mirrored). */
  rootsById: Record<string, Pick<Task, 'id' | 'currentCount' | 'action' | 'unit'>>;
  /** Source compound id → the compound row the derived compound copies from. */
  compoundsById: Record<
    string,
    Pick<Task, 'id' | 'operator' | 'threshold' | 'title' | 'description' | 'action' | 'unit'>
  >;
}

/** Output of {@link buildDerivedRows} — complete, writable rows. */
export interface DerivedRows {
  tasks: Task[];
  links: CompoundChild[];
}

/**
 * Materialise the {@link planDerivedTasks} drafts as complete `Task` /
 * `CompoundChild` rows. Pure — the caller writes them (in one transaction,
 * before the `board_tasks` rows that point at them).
 *
 * Derived counters come first, in draft order, then the derived compounds;
 * every row keeps the deterministic id its draft carries, so re-deriving the
 * same window overwrites rather than duplicates. A derived counter mirrors its
 * root's lifetime `currentCount` and reads its window value from that minus
 * `baseline`, so `isCompleted` at mint is whatever `deriveDisplayedCount`
 * already says — a root that has raced past the target is born complete rather
 * than hand-initialised to false.
 *
 * @param input - See {@link DerivedRowsInput}.
 * @returns The derived Task rows and the derived compounds' child links.
 */
export function buildDerivedRows({
  drafts,
  userId,
  now,
  rootsById,
  compoundsById,
}: DerivedRowsInput): DerivedRows {
  const tasks: Task[] = [];
  const links: CompoundChild[] = [];

  for (const d of drafts.derivedTasks) {
    const mirror = rootsById[d.rootTaskId]?.currentCount ?? 0;
    const shown = deriveDisplayedCount(
      { baseline: d.baseline, maxCount: d.maxCount },
      { currentCount: mirror }
    );
    const row: Task = {
      id: d.id,
      userId,
      title: d.title,
      type: TaskType.COUNTING,
      // `planDerivedTasks` fills these with '' for an action-less counter;
      // an empty string is not a value — leave the column absent instead.
      action: d.action || undefined,
      unit: d.unit || undefined,
      maxCount: d.maxCount,
      sharedCounterId: d.rootTaskId,
      baseline: d.baseline,
      currentCount: mirror,
      isCompleted: shown.isCompleted,
      // Stamped here or never: every other write path stamps `completedAt` on
      // the false → true transition, and for a row born complete that
      // transition has already happened.
      completedAt: shown.isCompleted ? now : undefined,
      totalCompletions: 0,
      totalInstances: 0,
      createdInWizard: true,
      timeframe: d.timeframe,
      startDate: d.startDate ?? undefined,
      endDate: d.endDate ?? undefined,
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    };
    tasks.push(row);
  }

  for (const c of drafts.derivedCompounds) {
    const source = compoundsById[c.sourceCompoundId];
    const row: Task = {
      id: c.id,
      userId,
      title: c.title,
      description: source?.description,
      type: TaskType.COMPOUND,
      operator: c.operator,
      // `null` is not a storable threshold (the schema takes a positive
      // integer or nothing at all) — an absent threshold stays absent.
      threshold: c.threshold ?? undefined,
      // Written false for column uniformity and never read: a compound's
      // completion is derived from its children (see `evaluateCompound`).
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdInWizard: true,
      timeframe: c.timeframe,
      startDate: c.startDate ?? undefined,
      endDate: c.endDate ?? undefined,
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    };
    tasks.push(row);
    for (const k of c.children) {
      links.push({
        id: k.linkId,
        compoundTaskId: c.id,
        childTaskId: k.childTaskId,
        childIndex: k.childIndex,
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
      });
    }
  }

  return { tasks, links };
}
