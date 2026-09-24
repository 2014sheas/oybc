/**
 * Failure feedback for Counters Hub / Detail log + undo writes (2026-09 audit,
 * T1 Task 6 — web parity with iOS `attemptLoggedWrite` + the "Counter not
 * updated" alert). A rejected counter write must never surface as a success
 * toast and never be an unhandled rejection: callers branch on the boolean and
 * show `COUNTER_NOT_UPDATED_MESSAGE` in `CounterWriteError` on `false`.
 *
 * Kept DOM-free so it is unit-testable in this repo's node-env Vitest harness.
 */

/** Functional, non-marketing copy shown when a counter log/undo write fails. */
export const COUNTER_NOT_UPDATED_MESSAGE = 'Counter not updated. Try again.';

/**
 * Runs a counter write and reports whether it landed. Any rejection is logged
 * with `context` and swallowed, so the caller decides the UI from the result.
 *
 * @param context - Short label for the log line, e.g. `'hub log'`.
 * @param write - The Dexie write to attempt.
 * @returns `true` when the write resolved, `false` when it rejected.
 */
export async function attemptCounterWrite(
  context: string,
  write: () => Promise<unknown>,
): Promise<boolean> {
  try {
    await write();
    return true;
  } catch (err) {
    console.error(`[counters] ${context} failed`, err);
    return false;
  }
}
