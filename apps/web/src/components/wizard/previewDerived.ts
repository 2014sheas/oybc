/**
 * previewDerived.ts — the wizard Preview's member-rule DRY RUN (B3 RC6,
 * docs/BOARD_SOURCES.md §Member rules).
 *
 * Step 3 previews the board a person is about to create. The persist path
 * does not place every picked task verbatim: a counting member carrying a
 * target/vary rule, or a counter root with a window default, is placed with
 * PLACEMENT PARAMETERS (`targetOverride` / `titleOverride`, TASK_WINDOW_REWORK
 * slice 3b). Left alone, the Preview would show "Run 30 miles" for a cell the
 * board will actually carry as "Run 24 miles".
 *
 * So the Preview runs the SAME planner (`planDerivedTasks`) over the same
 * inputs and re-labels each cell whose placement carries parameters with
 * `withPlacementParams` — a synthetic stand-in `Task`, a display object,
 * never a row:
 *
 * - **no DB writes** — nothing here touches Dexie or the sync queue;
 * - **the roll is a SAMPLE** — the Preview seeds the planner from the
 *   Shuffle nonce (so one nonce always previews the same numbers and
 *   Shuffle visibly re-rolls), while persist rolls with the platform rng.
 *   The board a person gets carries a fresh roll inside the same range.
 *
 * One-off boards only. A repeating board's Preview is the 5b summary card —
 * it has no cell grid to stand tasks in, and its targets are pro-rated per
 * repeated window rather than once at create time.
 */

import {
  makeSeededRng,
  planDerivedTasks,
  withPlacementParams,
  type BoardWindow,
  type CompoundChild,
  type ExpandedSupply,
  type PlacementParams,
  type PlanTask,
  type VaryLevel,
} from '@oybc/shared';
import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import type { TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { rollExplicitGoal } from '../../db/operations/explicitGoalRoll';
import { resolveWizardDates } from './wizardDates';
import type { WizardPlacement } from './wizardPersist';

/**
 * The id→task universe the planner reads: the live library, this session's
 * not-yet-persisted pending tasks, and — last, so it wins — the placement's
 * own tasks, which `buildWizardPlacement` has already overlaid with any
 * staged inline edits. A member whose goal was just retyped in the pool row
 * previews against the NEW goal.
 */
function planTasksById(
  placement: WizardPlacement,
  controller: BoardWizardController,
  library: TaskLibrary,
): Record<string, PlanTask> {
  const out: Record<string, PlanTask> = {};
  for (const t of library.allTasks) out[t.id] = t;
  for (const [id, payload] of controller.pendingTasks) out[id] = payload.task;
  for (const t of placement) if (t !== null) out[t.id] = t;
  return out;
}

/**
 * Task id → the window of the source BOARD it was pulled from, keyed by
 * every id whose source window matters: each supplied member AND the
 * children of a compound member (a compound's parts pro-rate by the
 * CHILD's id — see `PlanDerivedTasksArgs.sourceWindowByTaskId`). Pool
 * sources have no window of their own and contribute nothing.
 *
 * Mirrors the persist path's construction in `db/operations/wizardBoard.ts`.
 */
function sourceWindowByTaskId(
  controller: BoardWizardController,
  supplies: ExpandedSupply[],
  childrenByCompoundId: Record<string, Pick<CompoundChild, 'childTaskId' | 'childIndex'>[]>,
): Record<string, BoardWindow | undefined> {
  const out: Record<string, BoardWindow | undefined> = {};
  for (const supply of supplies) {
    const w = controller.supplyInfoBySourceId[supply.source.sourceId]?.sourceWindow;
    if (w === undefined) continue;
    for (const id of supply.supplyTaskIds) {
      out[id] = w;
      for (const k of childrenByCompoundId[id] ?? []) out[k.childTaskId] = w;
    }
  }
  return out;
}

/**
 * The prospective board's window — the SAME resolution the Save handler
 * persists (including the plan-ahead `targetWindowDate`). A date validation
 * error (an unfinished CUSTOM range) resolves to a date-less window: the
 * Save button surfaces the error, and a date-less CUSTOM window has no
 * knowable length, so `autoTarget` falls back to each member's own goal
 * until the range is finished (owner ruling 2026-09-21 — auto targets are
 * no longer recurring-only, so the window IS read on a one-off plan).
 */
function previewWindow(controller: BoardWizardController): BoardWindow {
  const dates = resolveWizardDates(controller, controller.targetWindowDate ?? undefined);
  if ('error' in dates) {
    return { timeframe: controller.timeframe, startDate: null, endDate: null };
  }
  return {
    timeframe: controller.timeframe,
    startDate: dates.startDate,
    endDate: dates.endDate ?? null,
  };
}

/**
 * Re-label every placement cell whose planned placement carries parameters
 * with a synthetic stand-in showing the rolled target and its title.
 *
 * Pure and side-effect free. The planner is fed the placement's own order
 * (nulls skipped), so cell *i*'s task maps positionally to `placements[i]`.
 * The wizard's explicit per-cell parameters (`controller.placementParams`)
 * win over the planner's, exactly as the persist path merges them.
 *
 * The stand-in is `withPlacementParams(task, params, root)` and keeps the
 * ORIGINAL task's `id`. That is not cosmetic: the Save handler persists the
 * user's arranged order, and `persistWizardBoardRows` re-plans from
 * `placement.map((t) => t.id)`. A compound's `childTargets` change nothing a
 * cell renders, so a compound needs no stand-in.
 *
 * @param placement - The placement `buildWizardPlacement` just computed.
 * @param controller - Live wizard state (supplies, rules, window, manual ids).
 * @param library - The live task library (+ compound children).
 * @param rng - Seeded uniform `[0, 1)` source — one nonce, one preview.
 * @returns A new placement array; cells the rules don't touch are the same
 *   object references the caller passed in.
 */
export function applyPreviewDerivedCells(
  placement: WizardPlacement,
  controller: BoardWizardController,
  library: TaskLibrary,
  rng: () => number,
): WizardPlacement {
  const tasksById = planTasksById(placement, controller, library);
  const childrenByCompoundId = controller.childrenByCompoundId ?? {};
  // The controller's own Split-up expansion — every surface reads THIS
  // rather than re-deriving it (`?? []` only guards a partial test double).
  const supplies: ExpandedSupply[] = controller.expandedSupplies ?? [];

  const orderedIds: string[] = [];
  for (const t of placement) if (t !== null) orderedIds.push(t.id);
  if (orderedIds.length === 0) return placement;

  const manualTaskVary: Record<string, VaryLevel> = controller.manualTaskVary ?? {};
  const { placements } = planDerivedTasks({
    selectedIds: orderedIds,
    supplies,
    manualTaskIds: Array.from(controller.manualTaskIds),
    manualTaskVary,
    window: previewWindow(controller),
    // One-off only — the Preview's cell grid doesn't exist for a repeating
    // board, and the caller gates on `!controller.isRecurring`.
    mode: 'oneOff',
    tasksById,
    childrenByCompoundId,
    sourceWindowByTaskId: sourceWindowByTaskId(controller, supplies, childrenByCompoundId),
    rng,
  });

  const paramsByOriginalId = new Map<string, PlacementParams>();
  orderedIds.forEach((id, i) => {
    const planned = placements[i];
    if (planned === undefined) return;
    const { taskId: _taskId, ...planParams } = planned;
    const explicit = controller.placementParams?.get(id);
    const merged: PlacementParams = explicit ? { ...planParams, ...explicit } : planParams;
    // Same rule (and rng order) as the save: a hand-added counter's dice roll
    // around its explicit goal (iOS `BoardWizardPreviewDerived` → `overlaying`).
    if (explicit?.targetOverride != null && controller.manualTaskIds.has(id)) {
      const rolled = rollExplicitGoal(
        { target: explicit.targetOverride, kind: explicit.targetKind ?? 'discrete' },
        manualTaskVary[id] ?? 0,
        rng,
      );
      merged.targetOverride = rolled.target;
      merged.targetKind = rolled.kind;
    }
    if (merged.targetOverride != null || merged.titleOverride != null) paramsByOriginalId.set(id, merged);
  });
  if (paramsByOriginalId.size === 0) return placement;

  return placement.map((task) => {
    if (task === null) return task;
    const params = paramsByOriginalId.get(task.id);
    if (params === undefined) return task;
    // A legacy derived row planned onto its ROOT previews the root's task.
    const root = task.sharedCounterId ? tasksById[task.sharedCounterId] : undefined;
    // The stand-in previews UNSTARTED: the mirror columns of the original (a
    // legacy row carries another window's progress) are not this board's.
    return { ...withPlacementParams(task, params, root ?? task), currentCount: 0, baseline: 0 };
  });
}

/**
 * Warm-up steps discarded before the Preview's first roll.
 *
 * The LCG's first outputs are an AFFINE function of its seed, so the
 * consecutive nonces a Shuffle button produces (0, 1, 2 …) yield first
 * samples ~0.0004 apart — every re-roll would land in the same bucket and
 * Shuffle would look broken on a board with a single varied member. Two
 * steps multiply the seed's influence by `a²` and decorrelate adjacent
 * nonces completely, while keeping one nonce ⇒ one preview.
 */
const PREVIEW_RNG_WARMUP = 2;

/**
 * The seeded `[0, 1)` source the Preview rolls its targets from.
 *
 * @param shuffleNonce - The Preview's Shuffle counter (0 at mount).
 * @returns A generator that is deterministic per nonce and well-spread
 *   across adjacent ones (see {@link PREVIEW_RNG_WARMUP}).
 */
export function makePreviewRng(shuffleNonce: number): () => number {
  const rng = makeSeededRng(shuffleNonce);
  for (let i = 0; i < PREVIEW_RNG_WARMUP; i += 1) rng();
  return rng;
}

/** Options `buildWizardPlacement` accepts to run the Preview dry run. */
export interface PreviewRulesOptions {
  /**
   * The Preview's Shuffle nonce. A SEED, deliberately — not a generator.
   *
   * `buildWizardPlacement` builds a fresh `makePreviewRng(seed)` per call, so
   * every build for one seed reproduces the same preview. Handing a live
   * generator across builds made each build consume the NEXT samples: the
   * mount effect re-rolled the targets one frame after first paint, and any
   * `useLiveQuery` tick re-rolled them again with no Shuffle — the
   * late-mutation class this project has a standing rule about.
   */
  seed: number;
}
