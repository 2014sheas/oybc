import { TaskType } from '../constants/enums';
import type { BoardTask, PlacementChildTarget } from '../types/boardTask';
import type { Task, TaskEvent } from '../types';
import type { CountKind } from './countValue';
import { isWholeCountKind, quantizeCount, resolveCountKind } from './countValue';
import { counterCopyTitle, type CounterTitleSettings } from './taskTitle';
import type { CompoundWindowContext, LinkedCounterWindow, TaskWindowState } from './taskEvents';
import {
  boundWindowContextAtSeal,
  resolveDerivedCounterWindowState,
  resolveTaskWindowState,
} from './taskEvents';

/**
 * placementParams.ts — how a square READS its placement's parameters
 * (docs/TASK_WINDOW_REWORK.md, slice 2a).
 *
 * A `BoardTask` may carry a per-board goal (`targetOverride` in `targetKind`),
 * per-child goals for a compound (`childTargets`) and a per-board title
 * (`titleOverride`). Every kernel and surface resolves the PLACEMENT-ADJUSTED
 * task — the library row with its `maxCount` / `title` replaced — through
 * {@link withPlacementParams}, so one function owns the override rule. A
 * placement with no parameters resolves the library row unchanged (every
 * pre-rework row), and a leftover minted derived row keeps resolving as a
 * plain linked task over the host window.
 *
 * Swift twin: `Helpers/PlacementParams.swift`, pinned by
 * `placementParamsVectors.json`.
 */

/** The parameter slice of a placement a reader needs. */
export type PlacementParams = Pick<BoardTask, 'targetOverride' | 'targetKind' | 'childTargets' | 'titleOverride'>;

/**
 * A frozen goal expressed in `from`, read by a root whose current kind is
 * `to` (ruling 5: a kind switch never rewrites placements). The same rounding
 * the kind switch applies to a root's own goal (`planCountKindSwitch`):
 * whole kinds round half-up with a floor of 1, continuous quantizes to 2 dp.
 *
 * @param goal - The frozen target.
 * @param from - The kind it was frozen in.
 * @param to - The root's current kind.
 * @returns The goal in `to`.
 */
export function convertGoalToKind(goal: number, from: CountKind, to: CountKind): number {
  if (from === to) return goal;
  return isWholeCountKind(to) ? Math.max(1, Math.floor(quantizeCount(goal) + 0.5)) : quantizeCount(goal);
}

/**
 * A counting placement's goal on its board: `targetOverride` (converted from
 * `targetKind` into the task's current kind), else the task's own `maxCount`.
 *
 * @param task - The placed task (a root, a plain counter or a linked row —
 *   a linked row's `countKind` mirrors its root's).
 * @param placement - The placement, or absent for a context-less reader.
 * @returns The effective goal, or `undefined` when there is none.
 */
export function placementGoal(
  task: Pick<Task, 'maxCount' | 'countKind'> & Partial<Pick<Task, 'type'>>,
  placement: PlacementParams | null | undefined,
): number | undefined {
  const override = placement?.targetOverride;
  // A goal override means nothing on a non-counting task.
  if (override == null || (task.type != null && task.type !== TaskType.COUNTING)) return task.maxCount ?? undefined;
  const kind = resolveCountKind(task);
  return convertGoalToKind(override, placement?.targetKind ?? kind, kind);
}

/**
 * The goal a compound placement assigns to one DIRECT child, if any.
 *
 * @param placement - The compound's placement.
 * @param childId - The child task id.
 * @returns The child's goal on this board, or `undefined`.
 */
export function childTargetFor(placement: PlacementParams | null | undefined, childId: string): number | undefined {
  return placement?.childTargets?.find((c: PlacementChildTarget) => c.childId === childId)?.target;
}

/**
 * A square's title: `titleOverride` (ruling 4), else — for a counting task
 * placed with a goal override — the task's own title re-rendered at that goal
 * through the root's templates (`counterCopyTitle`: a custom name carries
 * verbatim, an auto one is regenerated), else the task's title.
 *
 * @param task - The placed task.
 * @param placement - The placement, or absent.
 * @param settings - The ROOT's name + templates for a linked task (absent for
 *   a root or plain counter, whose own fields apply).
 * @returns The title to render.
 */
export function placementTitle(
  task: Task,
  placement: PlacementParams | null | undefined,
  settings?: CounterTitleSettings | null,
): string {
  const override = placement?.titleOverride?.trim();
  if (override) return override;
  if (task.type !== TaskType.COUNTING || placement?.targetOverride == null) return task.title;
  const goal = placementGoal(task, placement);
  if (goal == null) return task.title;
  return counterCopyTitle(task, goal, settings ?? null);
}

/**
 * The placement-adjusted task every kernel and surface resolves: `maxCount`
 * replaced by {@link placementGoal} and `title` by {@link placementTitle}.
 * Returns the SAME object when the placement carries no parameter that
 * applies, so pre-rework rows cost nothing and identity checks still hold.
 *
 * @param task - The library row.
 * @param placement - Its placement on the board being read, or absent.
 * @param settings - The root's title settings for a linked task.
 * @returns The task to resolve on this board.
 */
export function withPlacementParams(
  task: Task,
  placement: PlacementParams | null | undefined,
  settings?: CounterTitleSettings | null,
): Task {
  if (!placement) return task;
  const hasGoal = task.type === TaskType.COUNTING && placement.targetOverride != null;
  const hasTitle = !!placement.titleOverride?.trim();
  if (!hasGoal && !hasTitle) return task;
  const out: Task = { ...task };
  if (hasGoal) out.maxCount = placementGoal(task, placement);
  out.title = placementTitle(task, placement, settings);
  return out;
}

/**
 * A DIRECT child of a compound, with the parent placement's `childTargets`
 * entry (if any) as its goal. Nested compounds' children keep their own.
 *
 * @param child - The child task.
 * @param childTargets - The parent placement's child targets.
 * @returns The child to resolve (the same object when no target applies).
 */
export function withChildTarget(child: Task, childTargets: PlacementChildTarget[] | null | undefined): Task {
  if (child.type !== TaskType.COUNTING || !childTargets?.length) return child;
  const target = childTargets.find((c) => c.childId === child.id)?.target;
  if (target == null) return child;
  return { ...child, maxCount: target };
}

/**
 * The state of a PRIMITIVE square (normal / counting, root or linked) on a
 * board — the one rule of docs/TASK_WINDOW_REWORK.md: the event owner's live
 * events inside the host window, scored against the placement's goal.
 * Compounds go through `evaluateCompound(…, placement.childTargets)` and
 * achievements through the derivation pass; this is the leaf.
 *
 * @param task - The placed task.
 * @param placement - Its placement (goal / title), or absent.
 * @param ctx - The host board's window context (`windowStart` null = lifetime).
 * @param settings - The root's title settings (title only; not read here).
 * @returns `{ isCompleted, count }`.
 */
export function resolveSquareState(
  task: Task,
  placement: PlacementParams | null | undefined,
  ctx: CompoundWindowContext,
): TaskWindowState {
  const effective = withPlacementParams(task, placement);
  // A linked row: the root's events over the host window, or its lifetime.
  const derived = resolveDerivedCounterWindowState(effective, ctx.eventsByTaskId, ctx);
  if (derived) return derived;
  const events: TaskEvent[] = ctx.eventsByTaskId[effective.id] ?? [];
  return resolveTaskWindowState(effective, events, ctx.windowStart, ctx.windowEnd ?? null);
}

/**
 * What a LINKED counting square or row SHOWS — a thin wrapper over
 * {@link resolveSquareState} (TASK_WINDOW_REWORK slice 2c: display = kernel),
 * so a cell can never paint green (or read N/N) while board stats count it
 * incomplete:
 *
 *   - `window` given (the placing board's `[startDate, endDate]`) → the ROOT's
 *     increment sum inside THAT window, whatever the row's own stamp says
 *     (context window wins, slice 0);
 *   - no `window` → {@link contextlessCounterState} (the root's lifetime
 *     events). Neither the row's own stamp, `currentCount − baseline` nor the
 *     latch is read; no event map reads as no events.
 *
 * `sealedAt` (the row's board is sealed) bounds every event at that instant
 * first — {@link boundWindowContextAtSeal}, the sealed re-derive's filter; an
 * unparseable value applies no bound. `placement` applies the square's
 * parameters (goal / kind / title) before resolving. Overshoot is shown;
 * never high-clamped.
 *
 * @param task           The linked counting task being rendered.
 * @param eventsByTaskId Non-deleted events grouped by `taskId`, or none.
 * @param sealedAt       The row's board `sealedAt`, when that board is sealed.
 * @param window         The placing board's window, when there is one.
 * @param placement      The square's placement parameters, when placed.
 * @returns `{ displayed, isCompleted }`.
 */
export function resolveLinkedCounterDisplay(
  task: Task,
  eventsByTaskId: Record<string, TaskEvent[]> | null | undefined,
  sealedAt?: string | null,
  window?: LinkedCounterWindow | null,
  placement?: PlacementParams | null,
): { displayed: number; isCompleted: boolean } {
  let events: Record<string, TaskEvent[]> = eventsByTaskId ?? {};
  const sealedAtMs = sealedAt ? new Date(sealedAt).getTime() : NaN;
  if (!Number.isNaN(sealedAtMs)) events = boundWindowContextAtSeal(events, sealedAtMs).eventsByTaskId;
  const ctx: CompoundWindowContext = {
    eventsByTaskId: events,
    windowStart: window?.startDate ?? null,
    windowEnd: window?.endDate ?? null,
  };
  const { count, isCompleted } = resolveSquareState(task, placement, ctx);
  return { displayed: count, isCompleted };
}
