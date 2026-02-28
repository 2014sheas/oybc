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

/**
 * Generates placeholder task names for demo and test sections.
 *
 * @param count - Number of task names to generate
 * @returns Array of strings in the format ["Task 1", "Task 2", ...]
 */
export function generateTaskNames(count: number): string[] {
  return Array.from({ length: count }, (_, i) => `Task ${i + 1}`);
}

/**
 * Returns a fixed list of realistic sample task titles for seeding the Board Generator.
 *
 * @returns Array of 10 sample task title strings
 */
export function generateSampleTaskTitles(): string[] {
  return [
    'Morning workout',
    'Read for 30 minutes',
    'Cook a meal at home',
    'Call a friend or family member',
    'Go for a walk outside',
    'Meditate for 10 minutes',
    'Try a new recipe',
    'Clean and tidy a room',
    'Write in a journal',
    'Learn something new',
  ];
}
