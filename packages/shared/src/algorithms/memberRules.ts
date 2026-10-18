/**
 * memberRules.ts — Board Sources "member rules" (docs/BOARD_SOURCES.md
 * §Member rules, B1 + B2).
 *
 * Pure arithmetic + planning for per-member rules on a pulled source: the
 * nominal window length of a timeframe, the pro-rated auto target when a
 * counting member crosses windows, the vary (dice) range and its seeded
 * roll (those four in `memberRuleTargets.ts`, re-exported here), Split-up
 * supply expansion, and the plan that decides — per selected id — the
 * placement parameters each square carries (TASK_WINDOW_REWORK slice 3b).
 *
 * The platform layers write the plan. No persistence, no platform code, no side
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
import type { PlacementChildTarget } from '../types/boardTask';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import type { BoardSourceSupply } from './boardSources';
import { countTargetStep, floorToCountStep, isWholeCountKind, quantizeCount, resolveCountKind } from './countValue';
import type { CountKind } from './countValue';
import { counterTimeframeDefault } from './counterPlacement';
import type { CounterSettingsFields } from './counterSettings';
import { autoTarget, nominalWindowDays, rollTarget } from './memberRuleTargets';

// Target arithmetic lives in memberRuleTargets.ts (1000-line cap); re-exported here.
export { autoTarget, nominalWindowDays, rollTarget, varyRange } from './memberRuleTargets';

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
    // Slice 3a: a board source's effective goals ride along (`goalByTaskId`).
    return { ...supply, supplyTaskIds: out, partOf };
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
  'id' | 'type' | 'title' | 'action' | 'unit' | 'maxCount' | 'sharedCounterId' | 'operator' | 'threshold' | 'countKind'
> &
  Pick<CounterSettingsFields, 'counterName' | 'titleTemplateSingular' | 'titleTemplatePlural' | 'timeframeGoals'>;

/**
 * One planned placement (TASK_WINDOW_REWORK slice 3b): the task a
 * `board_tasks` row points at and the parameters the square carries. The
 * planner emits ONE per selected id, in order — never a row to mint.
 *
 *   - `taskId` — the member itself.
 *   - `targetOverride` / `targetKind` — the planned per-window target, in the
 *     member's kind, present only when it differs from the task's own goal
 *     (a placement whose target equals the goal is the plain task).
 *   - `childTargets` — a re-targeted compound's per-child targets (direct
 *     children only), present only for children whose target differs.
 */
export interface PlannedPlacement {
  taskId: string;
  targetOverride?: number;
  targetKind?: CountKind;
  childTargets?: PlacementChildTarget[];
}

export interface PlanDerivedTasksArgs {
  /** The task ids picked for the board, in placement order. */
  selectedIds: string[];
  supplies: ExpandedSupply[];
  /** Hand-added ids — they win over any source copy. */
  manualTaskIds: string[];
  manualTaskVary: Record<string, VaryLevel>;
  window: BoardWindow;
  /**
   * Whether the board being assembled is one-off or recurring.
   *
   * **No longer gates the target math** (owner ruling 2026-09-21: one-off
   * boards pro-rate too — docs/BOARD_SOURCES.md §Member rules). Kept on the
   * contract because every caller already has it and the vector fixture uses
   * it as a label.
   */
  mode: PlanMode;
  /** Every id `selectedIds` / the supplies / the links name. */
  tasksById: Record<string, PlanTask>;
  childrenByCompoundId: Record<string, Pick<CompoundChild, 'childTaskId' | 'childIndex'>[]>;
  /** Board-source members' (and their compound children's) source windows. */
  sourceWindowByTaskId: Record<string, BoardWindow | undefined>;
  /**
   * Shared-counter roots by id (docs/SHARED_COUNTER_SETTINGS.md §2): a
   * linked member's timeframe default and title templates live on its root.
   * Optional — a root missing here is looked up in `tasksById`.
   */
  rootsById?: Record<string, CounterSettingsFields>;
  rng: () => number;
}

export interface PlanDerivedTasksResult {
  /** One per `selectedIds` entry, in `selectedIds` order. */
  placements: PlannedPlacement[];
}

/**
 * A member is LINKED to a shared counter — a legacy window-stamped derived
 * counter OR a hub-linked copy (`sharedCounterId` alone). Judged on
 * `sharedCounterId` alone, like the pre-rework planner.
 */
function isLinkedMember(t: PlanTask): boolean {
  return !!t.sharedCounterId;
}

/**
 * A counting task's own goal, or `null` when it is goal-less (an accumulator,
 * which has no target to pro-rate or vary). Whole kinds need `≥ 1` and floor
 * (pre-feature behaviour); continuous keeps any positive goal, quantized.
 */
function goalOf(t: Pick<PlanTask, 'maxCount' | 'countKind'>): number | null {
  if (typeof t.maxCount !== 'number') return null;
  if (isWholeCountKind(resolveCountKind(t))) return t.maxCount >= 1 ? Math.floor(t.maxCount) : null;
  return t.maxCount > 0 ? quantizeCount(t.maxCount) : null;
}

/**
 * Spec step 3 — decide, per selected id, what its `board_tasks` row points
 * at and which placement parameters it carries (TASK_WINDOW_REWORK slice 3b:
 * the planner emits parameters, never rows).
 *
 * Pure and deterministic for a seeded `rng`: at most one sample per roll,
 * taken in `selectedIds` order (and within a compound, in `childIndex`
 * order); a level-0 or degenerate range takes none.
 *
 * Precedence, in order: hand-added beats any source copy; among sources, the
 * FIRST supply that lists the id wins; a split part reads its part rule (the
 * parent's member-level `vary` is deliberately ignored in split mode); a
 * `target` — member-level OR part-level — is honoured on board sources only
 * (a pool member offers vary / split / part-exclusion and nothing else).
 *
 * Goal source: a board-sourced member's goal is the SUPPLYING placement's
 * effective goal (`goalByTaskId`, slice 3a), else the member's own; a
 * hand-added or pool-sourced ROOT with a timeframe default for this board
 * that differs from its own goal takes that default (docs/SHARED_COUNTER_SETTINGS.md
 * §2 — a source pull and a hand-add agree); a goal-less member pulled from a
 * board takes its root's default.
 *
 * Output rules: a placement carries `targetOverride` only when the resolved
 * (rolled) target differs from the task's own goal — so the old
 * "no identical clone" rule is now the general case; a linked member is
 * placed as itself (the kernel reads the host window since slice 0 — the
 * per-window copy is gone).
 *
 * @param args - See {@link PlanDerivedTasksArgs}.
 * @returns One {@link PlannedPlacement} per selected id.
 */
export function planDerivedTasks(args: PlanDerivedTasksArgs): PlanDerivedTasksResult {
  const {
    selectedIds,
    supplies,
    manualTaskIds,
    manualTaskVary,
    window,
    tasksById,
    childrenByCompoundId,
    sourceWindowByTaskId,
    rootsById = {},
    rng,
  } = args;
  const manual = new Set(manualTaskIds);
  /** The member's shared-counter root (itself when it is the root), if known. */
  const rootOf = (t: PlanTask): CounterSettingsFields | undefined =>
    t.sharedCounterId ? (rootsById[t.sharedCounterId] ?? tasksById[t.sharedCounterId]) : t;
  const targetDays = nominalWindowDays(window.timeframe, window.startDate, window.endDate);
  const placements: PlannedPlacement[] = [];

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
   * The final `min(max(step, floorToStep(base)), goal)` clamp is redundant
   * for on-step targets (`varyRange` re-clamps `t` identically) and is only
   * observable on an off-step explicit target (4.25 on a whole kind) — keep
   * it anyway, and port it verbatim, so the two platforms can never disagree
   * about a malformed stored rule.
   */
  const resolveTarget = (
    goal: number,
    explicit: number | undefined,
    fromBoard: boolean,
    taskIdForWindow: string,
    kind: CountKind
  ): number => {
    // docs/SHARED_COUNTER_SETTINGS.md §2: a board-sourced member consults its
    // root's timeframe default FIRST (so a source pull and a hand-add agree),
    // then pro-rates. The default is the target as-is, even above `goal`. No
    // kind fallback: the member has a goal of its own to pro-rate.
    const t = tasksById[taskIdForWindow];
    const root = t && explicit === undefined && fromBoard ? rootOf(t) : undefined;
    const dflt = root ? counterTimeframeDefault(root, window.timeframe, window, { kindFallback: false }) : null;
    if (dflt !== null) return dflt;
    const base =
      explicit ??
      (fromBoard ? autoTarget(goal, sourceDaysFor(taskIdForWindow), targetDays, kind) : goal);
    // R17: the goal itself is always a valid target as-is (26.25, 0.05).
    if (base >= goal) return goal;
    return Math.min(Math.max(countTargetStep(kind), floorToCountStep(base, kind)), goal);
  };
  /**
   * A supplied member's EFFECTIVE goal (slice 3a): the source placement's
   * `targetOverride` when the board source carries one (`goalByTaskId`), else
   * the member's own goal. A hand-added member reads its own.
   */
  const effectiveGoalOf = (id: string, t: PlanTask, sup: ExpandedSupply | undefined): number | null => {
    // Board sources only — a pool never carries goals (a stray map is ignored).
    const supplied = sup?.source.kind === 'board' ? sup.goalByTaskId?.[id] : undefined;
    if (typeof supplied === 'number' && supplied > 0) {
      return isWholeCountKind(resolveCountKind(t)) ? (supplied >= 1 ? Math.floor(supplied) : null) : quantizeCount(supplied);
    }
    return goalOf(t);
  };
  /**
   * The placement for `t` at the pre-vary `target` rolled by `vary`: the
   * override lands only when the rolled target differs from the task's own
   * goal.
   */
  const param = (t: PlanTask, target: number, vary: VaryLevel, effGoal?: number | null): PlannedPlacement => {
    // The vary clamp's ceiling: the member's goal, or a timeframe default
    // above it (a goal-less root's default IS its goal). Every pre-default
    // target is ≤ the goal, so this is the goal exactly as before.
    const goal = Math.max(effGoal ?? goalOf(t) ?? 0, target);
    const kind = resolveCountKind(t);
    const rolled = rollTarget(target, vary, goal, rng, kind);
    const out: PlannedPlacement = { taskId: t.id };
    const own = goalOf(t);
    if (own === null || rolled !== own) {
      out.targetOverride = rolled;
      out.targetKind = kind;
    }
    return out;
  };

  for (const id of selectedIds) {
    const t = tasksById[id];
    if (!t) {
      placements.push({ taskId: id });
      continue;
    }
    const isManual = manual.has(id);
    const sup = isManual ? undefined : supplying(id);
    const fromBoard = sup?.source.kind === 'board';
    const rules = sup?.source.memberRules ?? {};
    const parentId = sup?.partOf[id];

    if (t.type === TaskType.COUNTING) {
      // Slice 3a: a board-sourced member's goal is the SUPPLYING placement's
      // effective goal (its `targetOverride`, else its own `maxCount`) — a
      // root placed at 70 of 300 pro-rates from 70, never 300.
      const ownGoal = effectiveGoalOf(id, t, sup);
      // A hand-added or POOL-sourced ROOT with a timeframe default for this
      // board that differs from its own goal takes that default — the default
      // is also the vary roll's base (docs/SHARED_COUNTER_SETTINGS.md §2: a
      // source pull and a hand-add agree). A LINKED row keeps its own goal
      // (its user-chosen target). Pools still never pro-rate or take a target.
      const poolSourced = sup !== undefined && !fromBoard;
      const handDefault =
        (isManual || poolSourced) && !isLinkedMember(t) ? counterTimeframeDefault(t, window.timeframe, window) : null;
      if (handDefault !== null && handDefault !== ownGoal) {
        const handVary: VaryLevel = isManual
          ? (manualTaskVary[id] ?? 0)
          : parentId
            ? (rules[parentId]?.parts?.[id]?.vary ?? 0)
            : (rules[id]?.vary ?? 0);
        placements.push(param(t, handDefault, handVary, ownGoal));
        continue;
      }
      // A goal-less member pulled from a board takes its root's default as its goal.
      const sourcedDefault =
        ownGoal === null && fromBoard ? counterTimeframeDefault(rootOf(t) ?? {}, window.timeframe, window) : null;
      const goal = ownGoal ?? sourcedDefault;
      if (goal === null) {
        // Goal-less (an accumulator — including a goal-less LINKED member):
        // nothing to target, so it is placed as-is. `TaskSchema` requires a
        // goal on every non-hub-born counting task, so this is defensive.
        placements.push({ taskId: id });
        continue;
      }
      if (isManual) {
        // A hand-added member is placed as itself at its own goal — the kernel
        // reads the host window (slice 0), so a linked member needs no copy;
        // only a vary roll produces parameters.
        placements.push(param(t, goal, manualTaskVary[id] ?? 0, ownGoal));
        continue;
      }
      if (parentId) {
        // Split part — the part rule governs; the parent's `vary` is ignored.
        const part: BoardSourcePartRule = rules[parentId]?.parts?.[id] ?? {};
        const vary = part.vary ?? 0;
        // `target` — member- OR part-level — is honoured on board sources only;
        // a pool member offers vary / split / part-exclusion and nothing else.
        if (fromBoard || vary > 0) {
          const target = resolveTarget(
            goal,
            fromBoard ? part.target : undefined,
            fromBoard,
            id,
            resolveCountKind(t)
          );
          placements.push(param(t, target, vary, ownGoal));
          continue;
        }
        placements.push({ taskId: id });
        continue;
      }
      const rule: BoardSourceMemberRule = rules[id] ?? {};
      const vary = rule.vary ?? 0;
      if (fromBoard) {
        const target = resolveTarget(goal, rule.target, true, id, resolveCountKind(t));
        placements.push(param(t, target, vary, ownGoal));
        continue;
      }
      // Pool-sourced: vary only.
      placements.push(param(t, goal, vary, ownGoal));
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
        placements.push({ taskId: id });
        continue;
      }
      const childTargets: PlacementChildTarget[] = [];
      for (const k of kids) {
        const c = tasksById[k.childTaskId];
        // Slice 3a: a compound placement's `childTargets` arrive keyed by child id.
        const goal = c ? effectiveGoalOf(k.childTaskId, c, sup) : null;
        if (!c || c.type !== TaskType.COUNTING || goal === null) continue;
        const part: BoardSourcePartRule = rule.parts?.[k.childTaskId] ?? {};
        const vary: VaryLevel = part.vary ?? rule.vary ?? 0;
        // Board sources only, as in the split-part branch above.
        const hasTarget = fromBoard && (part.target !== undefined || (rule.vary ?? 0) > 0);
        if (!hasTarget && vary === 0) continue;
        const kind = resolveCountKind(c);
        const target = resolveTarget(goal, fromBoard ? part.target : undefined, fromBoard, k.childTaskId, kind);
        const rolled = rollTarget(target, vary, Math.max(goal, target), rng, kind);
        // An entry only when the child's target differs from its own goal.
        if (rolled === goalOf(c)) continue;
        childTargets.push({ childId: k.childTaskId, target: rolled });
      }
      placements.push(childTargets.length > 0 ? { taskId: id, childTargets } : { taskId: id });
      continue;
    }

    placements.push({ taskId: id });
  }
  return { placements };
}
