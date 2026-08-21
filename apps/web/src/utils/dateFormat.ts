/**
 * Shared date-display helpers for production views.
 *
 * Uses the user's locale so dates read naturally on whichever device
 * the app is running on. The playground still has its own `formatDate`
 * helper in `components/playground/playgroundUtils.ts`; collapsing
 * those into these helpers is a future cleanup.
 */

/**
 * Formats an ISO8601 string as a short localised date.
 *
 * Example (en-US): `"Apr 12, 2026"`
 *
 * @param isoString - ISO8601 date string
 * @returns Human-readable date string, or `'—'` if parsing fails
 */
export function formatDisplayDate(isoString: string): string {
  const date = new Date(isoString);
  if (isNaN(date.getTime())) return '—';
  return date.toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  });
}
