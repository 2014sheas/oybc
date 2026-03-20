/** Shared constants and utilities for all Playground components */

/** Mock user ID used consistently across all Playground features */
export const PLAYGROUND_USER_ID = 'playground-user-1';

/** Duration in ms before success messages auto-dismiss */
export const SUCCESS_DISMISS_MS = 3000;

/**
 * Returns CSS class for character count based on proximity to limit.
 * The returned class includes a base `charCount` class and a modifier
 * when the count is near or over the maximum.
 *
 * @param current - Current character count
 * @param max - Maximum allowed characters
 * @param styles - CSS module styles object with charCount, charCountWarning, charCountError
 * @returns CSS class string
 */
export function getCharCountClass(
  current: number,
  max: number,
  styles: Record<string, string>
): string {
  if (current > max) return `${styles.charCount} ${styles.charCountError}`;
  if (current >= max * 0.9) return `${styles.charCount} ${styles.charCountWarning}`;
  return styles.charCount;
}

/**
 * Returns the human-readable operator description for a composite operator.
 *
 * @param operatorType - The operator type ('AND', 'OR', or 'M_OF_N')
 * @param threshold - Required for M_OF_N; the minimum count
 * @param leafCount - Total number of leaf nodes
 * @returns Display string such as "All of", "Any of", or "At least 2 of 3"
 */
export function formatOperatorLabel(
  operatorType: string,
  threshold: number | undefined,
  leafCount: number
): string {
  if (operatorType === 'AND') return 'All of';
  if (operatorType === 'OR') return 'Any of';
  return `At least ${threshold ?? '?'} of ${leafCount}`;
}

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
