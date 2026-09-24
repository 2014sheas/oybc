import { computePoolHealth } from '@oybc/shared';
import type {
  Pool,
  PoolHealthResult,
  PoolHealthTemplateSupply,
  RecurringBoardTemplate,
  Task,
} from '@oybc/shared';

/**
 * Batches `computePoolHealth` across every pool on a surface (the Pools
 * browse cards, the pool picker's rows) — ONE pass over already-loaded
 * lookups, never a per-card query (this repo has been burned twice by
 * per-card DB reads; see CLAUDE.md's perf-constraint note for P2 Task 2).
 *
 * Sources-native (2026-09 audit T2): a template is judged by the pool its
 * next spawn could ACTUALLY deal from — `achievableTaskIdsByTemplateId`,
 * the roster's achievable pick from `useTemplateRosterHealth`
 * (`fetchTemplateSupplyResolution` → `computeRosterHealth`: every pool AND
 * board source, ranges, exclusions, the done-filter, Split-up expansion,
 * counter families, the resolvable hand-adds). The old path resolved the
 * `poolIds` mirror with `resolveMix`, so a pool + board record read as
 * short and a capped pool source read as full.
 *
 * A template with no entry in `achievableTaskIdsByTemplateId` (still
 * loading — pass `undefined` for the whole map) is left out. Callers must
 * NOT paint that partial answer as final: gate the list on
 * {@link isPoolHealthResolved} and show a loading state until it holds, or
 * the "Short on N boards" line appears after first paint (late mutation).
 *
 * This function does no I/O of its own.
 *
 * @param pools - Every pool on the surface.
 * @param templates - Candidate consumers (the user's repeating boards).
 * @param achievableTaskIdsByTemplateId - `RosterHealth.mixByTemplateId`,
 *   or `undefined` while it loads.
 * @param tasksById - id → Task, for each pool card's task count.
 * @returns pool id → that pool's health.
 */
export function computePoolHealthByPoolId(
  pools: readonly Pool[],
  templates: readonly RecurringBoardTemplate[],
  achievableTaskIdsByTemplateId: Record<string, string[]> | undefined,
  tasksById: Record<string, Task>,
): Record<string, PoolHealthResult> {
  const supplies: PoolHealthTemplateSupply[] = [];
  for (const template of templates) {
    const achievable = achievableTaskIdsByTemplateId?.[template.id];
    if (achievable === undefined) continue;
    supplies.push({ template, achievableSize: achievable.length });
  }

  const result: Record<string, PoolHealthResult> = {};
  for (const pool of pools) {
    result[pool.id] = computePoolHealth(pool, { templates: supplies, tasksById });
  }
  return result;
}

/**
 * Whether the achievable-pick map covers every candidate consumer, i.e.
 * whether {@link computePoolHealthByPoolId}'s answer is final for this
 * roster. A surface renders its loading state until this holds, so the
 * first paint of a pool card already carries its "Short on N boards" line.
 *
 * `computeRosterHealth` gives EVERY template an entry, so a map missing
 * one is either still loading or stale (the live query was computed for
 * an older roster and the new template's resolution hasn't landed).
 *
 * @param templates - Candidate consumers, or `undefined` while the
 *   templates query itself loads (a `[]` placeholder would read as
 *   "resolved" and paint cards with no warnings).
 * @param achievableTaskIdsByTemplateId - `RosterHealth.mixByTemplateId`,
 *   or `undefined` while it loads.
 * @returns `true` once every template has an achievable entry.
 */
export function isPoolHealthResolved(
  templates: readonly RecurringBoardTemplate[] | undefined,
  achievableTaskIdsByTemplateId: Record<string, string[]> | undefined,
): boolean {
  if (templates === undefined || achievableTaskIdsByTemplateId === undefined) return false;
  return templates.every((t) =>
    Object.prototype.hasOwnProperty.call(achievableTaskIdsByTemplateId, t.id),
  );
}
