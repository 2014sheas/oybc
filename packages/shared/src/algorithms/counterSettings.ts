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

// ─── The counter sheet's draft (the UI PR) ───────────────────────────────────

/**
 * The counter sheet's optional fields as typed: `''` / an absent goal = unset
 * (the derived default shows dimmed). Goals are in the kind's units.
 */
export interface CounterSettingsDraft {
  name: string;
  singular: string;
  plural: string;
  goals: Partial<Record<CounterGoalTimeframe, number | null>>;
}

/** The four settings as stored on a root; an absent key = absent (the default). */
export interface StoredCounterSettings {
  counterName?: string;
  titleTemplateSingular?: string;
  titleTemplatePlural?: string;
  timeframeGoals?: CounterTimeframeGoals;
}

/** The dimmed value each optional field shows while unset (`''` / null = nothing). */
export interface CounterSettingsDefaults {
  name: string;
  singular: string;
  plural: string;
  goals: Record<CounterGoalTimeframe, number | null>;
}

/** The root fields the sheet's defaults derive from (the sheet's LIVE noun / verb / kind). */
export type CounterSettingsContext = Pick<CounterSettingsFields, 'action' | 'unit' | 'countKind'>;

/**
 * The entered goals that are usable positive numbers.
 *
 * @param goals - The draft's goals.
 */
function enteredGoals(goals: CounterSettingsDraft['goals']): CounterTimeframeGoals {
  const out: CounterTimeframeGoals = {};
  for (const t of COUNTER_GOAL_TIMEFRAMES) {
    const v = goals[t];
    if (typeof v === 'number' && Number.isFinite(v) && v > 0) out[t] = v;
  }
  return out;
}

/**
 * The sheet's draft seeded from a stored root (`''` / absent for an unset field).
 *
 * @param root - The counter's root fields.
 * @returns The draft.
 */
export function counterSettingsDraftFromRoot(root: CounterSettingsFields): CounterSettingsDraft {
  return {
    name: storedText(root.counterName) ?? '',
    singular: storedText(root.titleTemplateSingular) ?? '',
    plural: storedText(root.titleTemplatePlural) ?? '',
    goals: { ...enteredGoals(root.timeframeGoals ?? {}) },
  };
}

/**
 * The dimmed defaults for a draft over the sheet's live context: the name is
 * `formatCounterName(action, unit)`, the plural is the default template, the
 * singular is the typed plural when there is one, else the default (D2), and
 * each unset goal derives from the entered ones (D4; nothing entered → none).
 *
 * @param context - The sheet's live verb / noun / kind.
 * @param draft - The typed draft.
 * @returns The defaults.
 */
export function counterSettingsDefaults(context: CounterSettingsContext, draft: CounterSettingsDraft): CounterSettingsDefaults {
  const templates = defaultTitleTemplates(context);
  const plural = templates.plural;
  const singular = storedText(draft.plural) ?? plural;
  return {
    name: formatCounterName(context.action, context.unit),
    singular,
    plural,
    goals: derivedTimeframeGoals({ countKind: context.countKind, timeframeGoals: enteredGoals(draft.goals) }),
  };
}

/**
 * The stored settings a draft resolves to (D3 — stored only when the user
 * typed something): a blank text field, or one equal to its dimmed default,
 * is absent. A typed goal is stored AS TYPED — never normalised against what
 * the other goals derive (dropping it would move the derived value of a cell
 * the user saw dimmed beside it); all cells clear → absent.
 *
 * @param context - The sheet's live verb / noun / kind.
 * @param draft - The typed draft.
 * @returns The stored settings (absent keys = absent).
 */
export function storedCounterSettingsFromDraft(
  context: CounterSettingsContext,
  draft: CounterSettingsDraft
): StoredCounterSettings {
  const defaults = counterSettingsDefaults(context, draft);
  const out: StoredCounterSettings = {};
  const name = storedText(draft.name);
  if (name !== null && name !== defaults.name) out.counterName = name;
  const plural = storedText(draft.plural);
  if (plural !== null && plural !== defaults.plural) out.titleTemplatePlural = plural;
  const singular = storedText(draft.singular);
  if (singular !== null && singular !== defaults.singular) out.titleTemplateSingular = singular;
  const goals = enteredGoals(draft.goals);
  if (Object.keys(goals).length > 0) out.timeframeGoals = goals;
  return out;
}

/**
 * The settings as stored on a root, in {@link StoredCounterSettings} shape
 * (blank text = absent; only positive goals).
 *
 * @param root - The counter's root fields.
 * @returns The stored settings.
 */
export function storedCounterSettings(root: CounterSettingsFields): StoredCounterSettings {
  const out: StoredCounterSettings = {};
  const name = storedText(root.counterName);
  if (name !== null) out.counterName = name;
  const singular = storedText(root.titleTemplateSingular);
  if (singular !== null) out.titleTemplateSingular = singular;
  const plural = storedText(root.titleTemplatePlural);
  if (plural !== null) out.titleTemplatePlural = plural;
  const goals = enteredGoals(root.timeframeGoals ?? {});
  if (Object.keys(goals).length > 0) out.timeframeGoals = goals;
  return out;
}

/** The keys of {@link StoredCounterSettings}. */
export const COUNTER_SETTINGS_KEYS = [
  'counterName',
  'titleTemplateSingular',
  'titleTemplatePlural',
  'timeframeGoals',
] as const;

/**
 * The setting keys whose stored value differs between `before` and `after`
 * (goals compared per timeframe) — the keys an edit-mode Save writes.
 *
 * @param before - The settings as stored.
 * @param after - The settings the draft resolves to.
 * @returns The changed keys, in {@link COUNTER_SETTINGS_KEYS} order.
 */
export function changedCounterSettingsKeys(
  before: StoredCounterSettings,
  after: StoredCounterSettings
): (typeof COUNTER_SETTINGS_KEYS)[number][] {
  return COUNTER_SETTINGS_KEYS.filter((k) => {
    if (k !== 'timeframeGoals') return (before[k] ?? null) !== (after[k] ?? null);
    const a = before.timeframeGoals ?? {};
    const b = after.timeframeGoals ?? {};
    return COUNTER_GOAL_TIMEFRAMES.some((t) => (a[t] ?? null) !== (b[t] ?? null));
  });
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
