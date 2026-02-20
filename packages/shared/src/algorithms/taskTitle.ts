/**
 * Generates a display title for a COUNTING task.
 *
 * If a non-empty providedTitle is given, returns it trimmed.
 * Otherwise, generates a title from action, maxCount, and unit.
 *
 * @param action - Action verb (e.g., "Read")
 * @param maxCount - Target count (e.g., 100), formatted as integer
 * @param unit - Unit of measurement (e.g., "pages")
 * @param providedTitle - Optional user-provided title
 * @returns The resolved task title string
 */
export function generateCounterTaskTitle(
  action: string,
  maxCount: number,
  unit: string,
  providedTitle?: string
): string {
  if (providedTitle && providedTitle.trim().length > 0) {
    return providedTitle.trim();
  }
  return `${action.trim()} ${Math.floor(maxCount)} ${unit.trim()}`;
}
