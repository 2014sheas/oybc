/**
 * counterName.ts — pair-derived counter display names (R1 — counters refresh).
 *
 * A counting task's identity is the `(action, unit)` pair: `action` is a
 * verb (e.g. "Do", "Read", "Run") — defaulting to `"Do"` when blank — and
 * `unit` is a plural noun (e.g. "push-ups", "pages", "miles").
 * `formatCounterName` derives a counter's display name from that pair,
 * eliding the default `"Do"` verb so a plain counter reads as its activity
 * rather than "Do push-ups":
 *
 * | action (verb)     | unit (noun)  | formatCounterName |
 * | ------------------ | ------------ | ------------------ |
 * | "Do" (or blank/null) | "push-ups" | "Push-ups"          |
 * | "Run"               | "miles"     | "Run miles"         |
 * | "Read"               | "pages"     | "Read pages"        |
 *
 * No schema change — this is a pure display-time derivation over the
 * existing `action`/`unit` columns; legacy rows with a blank action render
 * via the same "Do" backfill this function already does. Empty inputs
 * collapse to `""` so callers can fall back to a stored title (e.g.
 * `sharedCounterGroups.ts` / `linkableCounter.ts`: `formatCounterName(...) ||
 * task.title`). The iOS twin is `apps/ios/OYBC/Helpers/CounterName.swift`
 * (`CounterName.formatCounterName`) — keep both in sync.
 */

/** Upper-cases only the first character; the rest of the string is untouched. */
function capitalizeFirst(value: string): string {
  if (value.length === 0) return value;
  return value.charAt(0).toUpperCase() + value.slice(1);
}

/**
 * Derives a counter's display name from its `(action, unit)` pair.
 *
 * Both inputs are trimmed first. The effective verb is the trimmed
 * `action`, or `"Do"` when it's blank/null/undefined. When the effective
 * verb is `"Do"` (case-insensitive), it's elided from the result and the
 * trimmed noun is returned with only its first letter capitalized (e.g.
 * `"push-ups"` → `"Push-ups"`). Otherwise the result is `"{Verb} {noun}"`,
 * with only the verb's first letter capitalized — the noun is returned
 * exactly as typed (e.g. `"run"`, `"miles"` → `"Run miles"`).
 *
 * @param action - Verb, e.g. "Run"; trimmed; null/undefined/blank → "Do".
 * @param unit - Noun, e.g. "miles"; trimmed.
 * @returns The derived display name, or `""` when there's nothing to show
 *   (a blank/null noun paired with an effective "Do" verb) — callers should
 *   fall back to a stored title in that case.
 */
export function formatCounterName(
  action: string | null | undefined,
  unit: string | null | undefined,
): string {
  const noun = (unit ?? '').trim();
  const trimmedAction = (action ?? '').trim();
  const verb = trimmedAction.length > 0 ? trimmedAction : 'Do';
  const verbIsDo = verb.toLowerCase() === 'do';

  if (verbIsDo) {
    return noun.length > 0 ? capitalizeFirst(noun) : '';
  }

  const capitalizedVerb = capitalizeFirst(verb);
  return noun.length > 0 ? `${capitalizedVerb} ${noun}` : capitalizedVerb;
}
