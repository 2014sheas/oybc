/**
 * previewDerived.ts — the wizard Preview's member-rule DRY RUN (B3 RC6,
 * docs/BOARD_SOURCES.md §Member rules).
 *
 * Step 3 previews the board a person is about to create. Since B2 the
 * persist path no longer places every picked task verbatim: a counting
 * member carrying a target/vary rule is replaced by a window-stamped
 * DERIVED counter whose `maxCount` is the rolled target, and a One-square
 * compound with re-targeted parts is replaced by a derived compound. Left
 * alone, the Preview would show "Run 30 miles" for a cell the board will
 * actually carry as "Run 24 miles".
 *
 * So the Preview runs the SAME planner (`planDerivedTasks`) over the same
 * inputs and re-labels each cell the rules would re-mint with a synthetic
 * stand-in `Task` — a display object, never a row:
 *
 * - **no DB writes** — nothing here touches Dexie or the sync queue; the
 *   real mint happens inside the board-create transaction
 *   (`db/operations/derivedCounters.ts`);
 * - **`baselineByRootId` is `{}`** — the baseline only affects a derived
 *   counter's stored starting count, never the target or title this
 *   renders;
 * - **the roll is a SAMPLE** — the Preview seeds the planner from the
 *   Shuffle nonce (so one nonce always previews the same numbers and
 *   Shuffle visibly re-rolls), while persist mints with the platform rng.
 *   The board a person gets carries a fresh roll inside the same range.
 *
 * One-off boards only. A repeating board's Preview is the 5b summary card —
 * it has no cell grid to stand tasks in, and its targets are pro-rated
 * per spawned window rather than once at create time.
 */

import {
  makeSeededRng,
  planDerivedTasks,
  type BoardWindow,
  type CompoundChild,
  type ExpandedSupply,
  type PlanTask,
  type VaryLevel,
} from '@oybc/shared';
import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import type { TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { resolveWizardDates } from './wizardDates';
import type { WizardPlacement } from './wizardPersist';

/**
 * Board id used when the wizard has no draft row yet. Derived ids are a
 * pure function of `(boardId, rootTaskId)` and this dry run never writes
 * one, so the value only has to be stable within a render.
 */
const PREVIEW_BOARD_ID = 'preview';

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
 * Save button surfaces the error, and a one-off plan never reads the window
 * days anyway (auto targets are recurring-only).
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
 * Replace every placement cell the member rules would re-mint with a
 * synthetic stand-in carrying the rolled target and its generated title.
 *
 * Pure and side-effect free. The planner is fed the placement's own order
 * (nulls skipped), so cell *i*'s task maps positionally to `placementIds[i]`
 * — a replaced cell keeps its place, exactly as the persist path places it.
 *
 * The stand-in copies the original task and overrides only the four fields a
 * person can see change: `title`, `maxCount`, `action`, `unit`. Its `id`
 * stays the ORIGINAL's — see the comment at the swap; that is what keeps the
 * Save handler writing real `board_tasks` rows. Derived COMPOUNDS are
 * deliberately not stood in for either.
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
  const { placementIds, derivedTasks } = planDerivedTasks({
    selectedIds: orderedIds,
    supplies,
    manualTaskIds: Array.from(controller.manualTaskIds),
    manualTaskVary,
    boardId: controller.draftBoardId ?? PREVIEW_BOARD_ID,
    window: previewWindow(controller),
    // One-off only — the Preview's cell grid doesn't exist for a repeating
    // board, and the caller gates on `!controller.isRecurring`.
    mode: 'oneOff',
    tasksById,
    childrenByCompoundId,
    sourceWindowByTaskId: sourceWindowByTaskId(controller, supplies, childrenByCompoundId),
    // Display only — a baseline shifts a derived counter's starting count,
    // never the target or the title this renders.
    baselineByRootId: {},
    rng,
  });

  if (derivedTasks.length === 0) return placement;

  // ── What a stand-in may and may not change ────────────────────────────
  //
  // The stand-in keeps the ORIGINAL task's `id`. That is not cosmetic: the
  // Save handler persists `placementRef.current` (the user's arranged
  // order), and `persistWizardBoardRows` re-derives its own selection from
  // `placement.map((t) => t.id)` before minting the real derived rows. A
  // preview-only derived id fed back in would miss every `tasksById` lookup
  // and be written STRAIGHT into `board_tasks` — a placement row pointing at
  // a task that does not exist. Nothing renders a cell's id, so keeping the
  // original costs nothing and keeps the preview and the persist path
  // reading the same task graph (windowed events, compound children, the
  // staged-edit overlay all still resolve).
  //
  // Counting members only, likewise deliberately. A One-square compound that
  // re-targets its parts is ALSO replaced at mint time (by a derived
  // compound), but nothing about that is visible on a CELL: same title, same
  // type, same operator — only its children's targets differ, and a cell
  // renders none of them.
  const counterById = new Map(derivedTasks.map((d) => [d.id, d]));
  const rolledByOriginalId = new Map<string, (typeof derivedTasks)[number]>();
  orderedIds.forEach((id, i) => {
    const next = placementIds[i];
    if (next === undefined || next === id) return;
    const counter = counterById.get(next);
    if (counter !== undefined) rolledByOriginalId.set(id, counter);
  });
  if (rolledByOriginalId.size === 0) return placement;

  return placement.map((task) => {
    if (task === null) return task;
    const counter = rolledByOriginalId.get(task.id);
    if (counter === undefined) return task;
    return {
      ...task,
      title: counter.title,
      maxCount: counter.maxCount,
      action: counter.action || undefined,
      unit: counter.unit || undefined,
    };
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
  /** Seeded uniform `[0, 1)` source — the Preview passes its Shuffle nonce. */
  rng: () => number;
}
