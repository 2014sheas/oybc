/**
 * counterSettings.ts — per-counter settings on a shared counter's ROOT task
 * (docs/SHARED_COUNTER_SETTINGS.md §1): the editable name, the `#N`
 * singular / plural title templates, and the default goal per core
 * timeframe. Swift twin: `Helpers/CounterSettings.swift`; pinned by
 * `tests/fixtures/counterSettingsVectors.json`.
 *
 * Every field is optional and ABSENT means "the default" (D3 — never
 * backfilled, never written on read), so a counter nobody edited renders
 * byte-for-byte as before: an absent template falls through to the legacy
 * `"{action} {goal} {unit}"` formula, an absent name to `formatCounterName`.
 *
 * Deliberately imports nothing from `taskTitle.ts` (which delegates here) so
 * the two modules never form an import cycle.
 */

import { Timeframe } from '../constants/enums';
import { formatCounterName } from './counterName';
import { ceilToCountStep, formatCount, quantizeCount, type CountKind } from './countValue';
import { nominalWindowDays } from './memberRuleTargets';

/** The placeholder a title template carries for the count. */
export const COUNT_PLACEHOLDER = '#N';

/** The core timeframes a counter may carry a default goal for, shortest first. */
export const COUNTER_GOAL_TIMEFRAMES = ['daily', 'weekly', 'monthly', 'yearly'] as const;

/** One of {@link COUNTER_GOAL_TIMEFRAMES}. */
export type CounterGoalTimeframe = (typeof COUNTER_GOAL_TIMEFRAMES)[number];

/** Default goals per core timeframe, in the counter's kind units (minutes for Duration). */
export type CounterTimeframeGoals = Partial<Record<CounterGoalTimeframe, number>>;

/**
 * The fields of a counter root these helpers read. Structural (not
 * `Pick<Task, …>`) so this module stays free of the `types/` graph; a stored
 * `Task` satisfies it.
 */
export interface CounterSettingsFields {
  title?: string | null;
  action?: string | null;
  unit?: string | null;
  maxCount?: number | null;
  countKind?: CountKind | null;
  counterName?: string | null;
  titleTemplateSingular?: string | null;
  titleTemplatePlural?: string | null;
  timeframeGoals?: CounterTimeframeGoals | null;
}

/** A singular / plural template pair. */
export interface CounterTitleTemplates {
  singular: string;
  plural: string;
}

/**
 * A stored string field, trimmed, or null when absent / blank.
 *
 * @param value - The stored value.
 * @returns The trimmed value, or null.
 */
function storedText(value: string | null | undefined): string | null {
  const t = (value ?? '').trim();
  return t.length > 0 ? t : null;
}

/**
 * The count as a title renders it: locale-independent (titles are stored
 * data) — `Xh Ym` for Duration, else the 2dp-trimmed number. Exactly the
 * legacy generator's rendering, so a default template and the legacy
 * formula agree byte for byte.
 *
 * @param goal - The goal.
 * @param kind - The counter's kind.
 * @returns The count text.
 */
export function formatTitleCount(goal: number, kind: CountKind): string {
  return kind === 'duration' ? formatCount(goal, 'duration') : String(quantizeCount(goal));
}

/**
 * The default templates for a root's fields (spec §1b): `"{action} #N {unit}"`
 * (Duration: `"{action} #N"`); the singular defaults to the plural (D2 — no
 * singular-noun field).
 *
 * @param root - The root's fields.
 * @returns The default pair.
 */
export function defaultTitleTemplates(root: CounterSettingsFields): CounterTitleTemplates {
  const action = (root.action ?? '').trim();
  const plural =
    root.countKind === 'duration'
      ? `${action} ${COUNT_PLACEHOLDER}`
      : `${action} ${COUNT_PLACEHOLDER} ${(root.unit ?? '').trim()}`;
  return { singular: plural, plural };
}

/**
 * The templates in effect: a stored plural, else the default; a stored
 * singular, else the effective plural (D2).
 *
 * @param root - The root's fields.
 * @returns The effective pair.
 */
export function effectiveTitleTemplates(root: CounterSettingsFields): CounterTitleTemplates {
  const plural = storedText(root.titleTemplatePlural) ?? defaultTitleTemplates(root).plural;
  return { singular: storedText(root.titleTemplateSingular) ?? plural, plural };
}

/**
 * The counter's name without a title fallback: the stored `counterName`, else
 * `formatCounterName(action, unit)` (may be `''`).
 *
 * @param root - The root's fields.
 * @returns The name.
 */
function nameFromFields(root: CounterSettingsFields): string {
  return storedText(root.counterName) ?? formatCounterName(root.action, root.unit);
}

/**
 * The label the hub, Counter Detail, pickers and quick-add show (spec §1a):
 * `counterName`, else `formatCounterName(action, unit)`, else the stored title.
 *
 * @param root - The root's fields.
 * @returns The display name.
 */
export function counterDisplayName(root: CounterSettingsFields): string {
  return nameFromFields(root) || (root.title ?? '').trim();
}

/**
 * Render a counter's title for `goal` (spec §1b rendering rule): `goal == 1`
 * → the singular template, else the plural; `#N` → {@link formatTitleCount};
 * a template without `#N` renders as-is. A goal-less row renders the name.
 * With no stored template the legacy formula renders unchanged (inert for
 * untouched counters — not even trimmed).
 *
 * @param root - The root's fields (the action / unit / kind of the row being titled).
 * @param goal - The row's goal, or null / undefined for goal-less.
 * @returns The title.
 */
export function renderCounterTitle(root: CounterSettingsFields, goal: number | null | undefined): string {
  if (goal == null) return nameFromFields(root);
  const kind = root.countKind ?? 'discrete';
  const plural = storedText(root.titleTemplatePlural);
  const template = goal === 1 ? (storedText(root.titleTemplateSingular) ?? plural) : plural;
  const count = formatTitleCount(goal, kind);
  if (template === null) {
    const action = (root.action ?? '').trim();
    return kind === 'duration' ? `${action} ${count}` : `${action} ${count} ${(root.unit ?? '').trim()}`;
  }
  return template.split(COUNT_PLACEHOLDER).join(count).trim();
}

/**
 * Whether `t` is one of the four core goal timeframes.
 *
 * @param t - A timeframe value.
 */
function isGoalTimeframe(t: string): t is CounterGoalTimeframe {
  return (COUNTER_GOAL_TIMEFRAMES as readonly string[]).includes(t);
}

/**
 * A stored goal when it is a usable positive number, else null.
 *
 * @param goals - The stored map.
 * @param t - The timeframe.
 */
function storedGoal(goals: CounterTimeframeGoals | null | undefined, t: CounterGoalTimeframe): number | null {
  const v = goals?.[t];
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : null;
}

/**
 * The goal D4 derives for `target` from the nearest SET timeframe (by
 * position in {@link COUNTER_GOAL_TIMEFRAMES}; a tie goes to the shorter
 * one), scaled by the nominal window ratio (1 / 7 / 30 / 365 days — the
 * member-rule auto-scaler's `nominalWindowDays`) and rounded up to the
 * kind's step (`ceilToCountStep`, the auto-scaler's rounding). Null when no
 * timeframe is set or `target` itself is set.
 *
 * @param root - The root's fields.
 * @param target - The timeframe to derive.
 * @returns The derived goal, or null.
 */
function derivedGoal(root: CounterSettingsFields, target: CounterGoalTimeframe): number | null {
  if (storedGoal(root.timeframeGoals, target) !== null) return null;
  const ti = COUNTER_GOAL_TIMEFRAMES.indexOf(target);
  let best: { t: CounterGoalTimeframe; d: number } | null = null;
  for (const t of COUNTER_GOAL_TIMEFRAMES) {
    if (storedGoal(root.timeframeGoals, t) === null) continue;
    const d = Math.abs(COUNTER_GOAL_TIMEFRAMES.indexOf(t) - ti);
    if (best === null || d < best.d) best = { t, d };
  }
  if (best === null) return null;
  const source = storedGoal(root.timeframeGoals, best.t) as number;
  const sourceDays = nominalWindowDays(best.t as Timeframe) as number;
  const targetDays = nominalWindowDays(target as Timeframe) as number;
  return ceilToCountStep((source * targetDays) / sourceDays, root.countKind ?? 'discrete');
}

/**
 * The derived (dimmed) default for every UNSET core timeframe (D4); a set
 * timeframe, or every timeframe when none is set, maps to null.
 *
 * @param root - The root's fields.
 * @returns One entry per core timeframe.
 */
export function derivedTimeframeGoals(root: CounterSettingsFields): Record<CounterGoalTimeframe, number | null> {
  return {
    daily: derivedGoal(root, 'daily'),
    weekly: derivedGoal(root, 'weekly'),
    monthly: derivedGoal(root, 'monthly'),
    yearly: derivedGoal(root, 'yearly'),
  };
}

/**
 * The default goal a counter brings to a board of `timeframe` (spec §1c):
 * the stored default → else one derived from the set defaults (D4) → else
 * the root's own goal → else null. A CUSTOM or INDEFINITE board never
 * matches a default (null).
 *
 * @param root - The root's fields.
 * @param timeframe - The board's timeframe.
 * @returns The goal, or null.
 */
export function resolveCounterDefaultGoal(root: CounterSettingsFields, timeframe: Timeframe | string): number | null {
  if (!isGoalTimeframe(timeframe)) return null;
  const goal = storedGoal(root.timeframeGoals, timeframe) ?? derivedGoal(root, timeframe);
  if (goal !== null) return goal;
  const own = root.maxCount;
  return typeof own === 'number' && own > 0 ? own : null;
}
