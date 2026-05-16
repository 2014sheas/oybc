/**
 * Thin wrapper around `Intl.RelativeTimeFormat` for human-readable
 * relative timestamps ("just now", "5m ago", "3h ago", "2d ago", "3w ago").
 * Returns an absolute locale date string for intervals beyond 1 year.
 * Returns null when the input is undefined or cannot be parsed as a date.
 *
 * @param iso - ISO 8601 date string, or undefined
 * @returns human-readable relative time string, or null
 */
export function formatRelativeTime(iso: string | undefined): string | null {
  if (iso === undefined || iso === '') return null;
  const date = new Date(iso);
  if (!Number.isFinite(date.getTime())) return null;

  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
  const diffMs = date.getTime() - Date.now();
  const diffSec = Math.round(diffMs / 1000);
  const absSec = Math.abs(diffSec);

  if (absSec < 60) return 'just now';
  if (absSec < 3600) return rtf.format(Math.round(diffSec / 60), 'minute');
  if (absSec < 86400) return rtf.format(Math.round(diffSec / 3600), 'hour');
  if (absSec < 7 * 86400) return rtf.format(Math.round(diffSec / 86400), 'day');
  if (absSec < 365 * 86400) return rtf.format(Math.round(diffSec / (7 * 86400)), 'week');
  return date.toLocaleDateString();
}
