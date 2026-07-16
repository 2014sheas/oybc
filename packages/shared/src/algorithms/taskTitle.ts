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
  // P5 — hub-born counters are goal-less accumulators; title carries the
  // activity + unit ("Push-ups (reps)") so same-activity counters with
  // different units stay distinguishable.
  if (maxCount == null) {
    return `${action.trim()} (${unit.trim()})`;
  }
  return `${action.trim()} ${Math.floor(maxCount)} ${unit.trim()}`;
}
