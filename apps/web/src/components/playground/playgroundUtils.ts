/** Shared constants and utilities for all Playground components */

/** Mock user ID used consistently across all Playground features */
export const PLAYGROUND_USER_ID = 'playground-user-1';

/** Duration in ms before success messages auto-dismiss */
export const SUCCESS_DISMISS_MS = 3000;

/**
 * Formats an ISO8601 date string for display.
 *
 * @param isoString - ISO8601 date string
 * @returns Human-readable date string
 */
export function formatDate(isoString: string): string {
  return new Date(isoString).toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}
