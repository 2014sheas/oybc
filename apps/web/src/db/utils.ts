/**
 * Database utility functions
 */

/**
 * Generate UUID v4
 */
export function generateUUID(): string {
  return crypto.randomUUID();
}

/**
 * Get current ISO8601 timestamp
 */
export function currentTimestamp(): string {
  return new Date().toISOString();
}
