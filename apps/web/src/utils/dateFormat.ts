/**
 * Shared date-display helpers.
 *
 * Centralised here so production views and the playground share one
 * implementation. Uses the user's locale so dates read naturally on
 * whichever device the app is running on.
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

/**
 * Formats an ISO8601 string as a short localised date with time.
 *
 * Example (en-US): `"Apr 12, 2026, 2:45 PM"`
 *
 * @param isoString - ISO8601 date string
 * @returns Human-readable date+time string, or `'—'` if parsing fails
 */
export function formatDisplayDateTime(isoString: string): string {
  const date = new Date(isoString);
  if (isNaN(date.getTime())) return '—';
  return date.toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}
