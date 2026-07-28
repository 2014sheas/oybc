import { formatCounterName } from './counterName';

/**
 * Generates a display title for a COUNTING task.
 *
 * If a non-empty providedTitle is given, returns it trimmed.
 * Otherwise, generates a title from action, maxCount, and unit.
 *
 * @param action - Action verb (e.g., "Read")
 * @param maxCount - Target count (e.g., 100), formatted as integer, or null/undefined for a goal-less hub-born counter
 * @param unit - Unit of measurement (e.g., "pages")
 * @param providedTitle - Optional user-provided title
 * @returns The resolved task title string
 */
export function generateCounterTaskTitle(
  action: string,
  maxCount: number | null | undefined,
  unit: string,
  providedTitle?: string
): string {
  if (providedTitle && providedTitle.trim().length > 0) {
    return providedTitle.trim();
  }
  // Goal-less hub-born counters are accumulators with no numeric target —
  // the title IS the pair-derived counter display name (design 2026-07-18,
  // R1 counters refresh). The earlier P5 "{action} ({unit})" parenthetical
  // is retired: "Do" + "push-ups" now renders "Push-ups", "Run" + "miles"
  // renders "Run miles" — see `formatCounterName`.
  if (maxCount == null) {
    return formatCounterName(action, unit);
  }
  return `${action.trim()} ${Math.floor(maxCount)} ${unit.trim()}`;
}
