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
