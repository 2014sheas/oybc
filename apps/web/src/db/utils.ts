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

/**
 * Parse ISO8601 timestamp to Date
 */
export function parseTimestamp(timestamp: string): Date {
  return new Date(timestamp);
}

/**
 * Check if timestamp is within the last N milliseconds
 */
export function isRecent(timestamp: string, ms: number): boolean {
  const date = parseTimestamp(timestamp);
  const now = Date.now();
  return now - date.getTime() < ms;
}
