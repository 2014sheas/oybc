/**
 * poolHealth.ts — Task Pools + Recurring Boards Rework (P2)
 *
 * Pure functions deriving a `Pool`'s "health" — whether it currently
 * supplies enough resolvable tasks for every repeating board (spawn
 * record) that draws from it — and the exact copy for the resulting
 * warning. Health is NEVER stored (docs/POOLS_RECURRING.md §Data model →
 * New entity: Pool): pool cards, roster rows, and (while it exists)
 * template rows all derive from this single source, so a fix here heals
 * every surface at once.
 *
 * No persistence; no platform code; no side effects. Has a Swift twin:
 * `apps/ios/OYBC/Helpers/PoolHealth.swift` (Task 3), mirrored case-for-case.
 *
 * Canonical design: docs/POOLS_RECURRING.md §Data model (health derived) +
 * §Behavior invariants (fillable floor everywhere).
 */

import { fillableCellCount } from '@oybc/bingo-core';
import { resolveMix } from './poolMix';
import { Timeframe } from '../constants/enums';
import type { Pool } from '../types/pool';
import type { RecurringBoardTemplate } from '../types/recurringBoardTemplate';
import type { Task } from '../types/task';

/**
 * A single repeating board (spawn record) that is short on this pool —
 * i.e. its resolved mix doesn't reach its own fillable floor. Only
 * `shortBy > 0` templates ever appear as a consumer; a template that pulls
 * the pool but is otherwise fully supplied is not included.
 */
export interface PoolHealthConsumer {
  templateId: string;
  templateName: string;
  timeframe: Timeframe;
  /** How many more resolvable tasks the template's mix needs. Always > 0. */
  shortBy: number;
}

/**
 * Result of `computePoolHealth`.
 */
export interface PoolHealthResult {
  /** Resolvable (present, non-deleted) count of `pool.taskIds`. */
  taskCount: number;
  /**
   * Every non-deleted, active template that pulls this pool AND is short
   * on its own fillable floor, in `templates` input order.
   */
  consumers: PoolHealthConsumer[];
}

/**
 * Inputs `computePoolHealth` needs to resolve a pool's consumers. Callers
 * compute these ONCE per page/screen (batched) — never per-card — since
 * every pool on a surface shares the same template/pool/task lookups.
 */
export interface ComputePoolHealthInput {
  /** Candidate consumers — filtered internally to non-deleted + active. */
  templates: RecurringBoardTemplate[];
  /** Lookup for every id in each template's `poolIds` (passed to `resolveMix`). */
  poolsById: Record<string, Pool>;
  /** Lookup for filtering `pool.taskIds` / each template's resolved mix. */
  tasksById: Record<string, Task>;
}

/**
 * Derives a pool's resolvable task count and the set of repeating boards
 * (spawn records) that consume it and are short.
 *
 * A template is a consumer only when ALL of:
 *   - not soft-deleted (`isDeleted === false`)
 *   - active (`isActive === true`) — a paused template can't spawn, so a
 *     short mix there isn't actionable
 *   - its `poolIds` includes `pool.id`
 *   - its resolved mix (`resolveMix`, reused verbatim — no reimplementation)
 *     falls short of its own `fillableCellCount(boardSize, centerSquareType)`
 *
 * @param pool - The pool whose health is being derived.
 * @param input - Batched lookups; see `ComputePoolHealthInput`.
 */
export function computePoolHealth(
  pool: Pool,
  input: ComputePoolHealthInput,
): PoolHealthResult {
  const { templates, poolsById, tasksById } = input;

  const taskCount = pool.taskIds.filter((taskId) => {
    const task = tasksById[taskId];
    return task !== undefined && !task.isDeleted;
  }).length;

  const consumers: PoolHealthConsumer[] = [];
  for (const template of templates) {
    if (template.isDeleted || !template.isActive) continue;
    if (!(template.poolIds ?? []).includes(pool.id)) continue;

    const mix = resolveMix(template, poolsById, tasksById);
    const floor = fillableCellCount(template.boardSize, template.centerSquareType);
    const shortBy = Math.max(0, floor - mix.taskIds.length);
    if (shortBy <= 0) continue;

    consumers.push({
      templateId: template.id,
      templateName: template.name,
      timeframe: template.timeframe,
      shortBy,
    });
  }

  return { taskCount, consumers };
}

/**
 * Displayed label for each `Timeframe` in the warning copy. `CUSTOM` /
 * `INDEFINITE` never reach here — repeating boards (spawn records) exclude
 * both (docs/POOLS_RECURRING.md), but a fallback keeps this total.
 */
const TIMEFRAME_LABELS: Record<Timeframe, string> = {
  [Timeframe.DAILY]: 'Daily',
  [Timeframe.WEEKLY]: 'Weekly',
  [Timeframe.MONTHLY]: 'Monthly',
  [Timeframe.YEARLY]: 'Yearly',
  [Timeframe.CUSTOM]: 'Custom',
  [Timeframe.INDEFINITE]: 'Indefinite',
};

/**
 * Fields `formatPoolShortWarning` needs — a subset of `PoolHealthConsumer`
 * plus the consuming template's `boardSize` (not carried on the consumer
 * itself, since the floor's `shortBy` is already baked in).
 */
export interface PoolShortWarningInput {
  shortBy: number;
  boardSize: number;
  timeframe: Timeframe;
}

/**
 * Formats the single, cross-platform-shared copy for a short pool
 * consumer: `"{N} short of a {S}×{S} — {Timeframe} reset can't spawn"`
 * (e.g. `"2 short of a 3×3 — Weekly reset can't spawn"`). Web and iOS
 * render this string verbatim — do not hand-roll the copy on either
 * platform.
 */
export function formatPoolShortWarning(input: PoolShortWarningInput): string {
  const { shortBy, boardSize, timeframe } = input;
  const timeframeLabel = TIMEFRAME_LABELS[timeframe];
  return `${shortBy} short of a ${boardSize}×${boardSize} — ${timeframeLabel} reset can't spawn`;
}
