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
import { isSourceSupplyTask, sourcesForRecord } from './boardSources';
import { Timeframe } from '../constants/enums';
import type { Pool } from '../types/pool';
import type { RecurringBoardTemplate } from '../types/recurringBoardTemplate';
import type { Task } from '../types/task';

/**
 * A single repeating board (spawn record) that is short on this pool —
 * i.e. its ACHIEVABLE pool (every source + hand-adds, as the spawn
 * resolves them) doesn't reach its own fillable floor. Only `shortBy > 0`
 * templates ever appear as a consumer; a template that pulls the pool but
 * is otherwise fully supplied is not included.
 */
export interface PoolHealthConsumer {
  templateId: string;
  templateName: string;
  timeframe: Timeframe;
  /** The consuming template's board size. Not read by the card's combined
   *  `formatPoolShortSummary` line (which only counts consumers), but kept
   *  on the consumer for any other per-template rendering. */
  boardSize: number;
  /** How many more tasks the template's achievable pool needs. Always > 0. */
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
 * One candidate consumer, PRE-RESOLVED: the template plus the size of the
 * pool its next spawn could actually deal from. The size is DB-derived
 * (board-kind sources need live boards), so the pure health function never
 * computes it — callers resolve it through the sources-native roster path
 * (web `fetchTemplateSupplyResolution` → `computeRosterHealth`; iOS
 * `AppDatabase.fetchTemplateSupplyResolution` →
 * `RecurringBoardTemplatesViewModel.computeRosterHealth`), i.e.
 * `computeAchievablePoolSize` over every source (pool AND board kinds,
 * ranges, exclusions, the done-filter, Split-up expansion, counter
 * families) plus the resolvable hand-added layer.
 */
export interface PoolHealthTemplateSupply {
  template: RecurringBoardTemplate;
  /** Distinct tasks the template's next spawn could deal from. */
  achievableSize: number;
}

/**
 * Inputs `computePoolHealth` needs to resolve a pool's consumers. Callers
 * compute these ONCE per page/screen (batched) — never per-card — since
 * every pool on a surface shares the same template/task lookups.
 */
export interface ComputePoolHealthInput {
  /** Candidate consumers with their resolved achievable size — filtered
   *  internally to non-deleted + active + actually-pulls-this-pool. */
  templates: readonly PoolHealthTemplateSupply[];
  /** Lookup for filtering `pool.taskIds` into the card's task count. */
  tasksById: Record<string, Task>;
}

/**
 * Whether `template` pulls `poolId` — i.e. one of its `sources` is that
 * pool (`kind === 'pool'`, `sourceId === poolId`). Read through
 * `sourcesForRecord`, so an un-migrated v1 record's `poolIds` still count
 * via the decode-time `[0, all]` mapping, but a record WITH `sources` is
 * judged by them alone (its `poolIds` mirror is never consulted).
 *
 * @param template - The candidate consumer.
 * @param poolId - The pool in question.
 * @returns `true` when a pool-kind source names `poolId`.
 */
export function templateConsumesPool(
  template: RecurringBoardTemplate,
  poolId: string,
): boolean {
  return sourcesForRecord(template).some(
    (source) => source.kind === 'pool' && source.sourceId === poolId,
  );
}

/**
 * Derives a pool's resolvable task count and the set of repeating boards
 * (spawn records) that consume it and are short.
 *
 * A template is a consumer only when ALL of:
 *   - not soft-deleted (`isDeleted === false`)
 *   - active (`isActive === true`) — a paused template can't spawn, so a
 *     short pool there isn't actionable
 *   - one of its sources is this pool (`templateConsumesPool`)
 *   - its pre-resolved `achievableSize` falls short of its own
 *     `fillableCellCount(boardSize, centerSquareType)`
 *
 * @param pool - The pool whose health is being derived.
 * @param input - Batched, pre-resolved inputs; see `ComputePoolHealthInput`.
 * @returns The pool's task count and its short consumers.
 */
export function computePoolHealth(
  pool: Pool,
  input: ComputePoolHealthInput,
): PoolHealthResult {
  const { templates, tasksById } = input;

  // Supply-eligible only (`isSourceSupplyTask` — achievements are banned
  // from pools) so the card's count and warnings agree with what the
  // wizard/spawn can actually pull.
  const taskCount = pool.taskIds.filter((taskId) => {
    const task = tasksById[taskId];
    return task !== undefined && !task.isDeleted && isSourceSupplyTask(task);
  }).length;

  const consumers: PoolHealthConsumer[] = [];
  for (const { template, achievableSize } of templates) {
    if (template.isDeleted || !template.isActive) continue;
    if (!templateConsumesPool(template, pool.id)) continue;

    const floor = fillableCellCount(template.boardSize, template.centerSquareType);
    const shortBy = Math.max(0, floor - achievableSize);
    if (shortBy <= 0) continue;

    consumers.push({
      templateId: template.id,
      templateName: template.name,
      timeframe: template.timeframe,
      boardSize: template.boardSize,
      shortBy,
    });
  }

  return { taskCount, consumers };
}

/**
 * Formats the single, cross-platform-shared pool-CARD warning line —
 * board-count syntax, combining every short consumer into one line
 * instead of one line per consumer (owner decision, 2026-07-20; see
 * docs/POOLS_RECURRING.md §Surfaces item 1): `''` when there are no short
 * consumers (render nothing), `'Short on 1 board'` for exactly one, or
 * `'Short on {N} boards'` for two or more. Web and iOS render this string
 * verbatim — do not hand-roll the copy on either platform.
 */
export function formatPoolShortSummary(consumers: PoolHealthConsumer[]): string {
  if (consumers.length === 0) return '';
  if (consumers.length === 1) return 'Short on 1 board';
  return `Short on ${consumers.length} boards`;
}
