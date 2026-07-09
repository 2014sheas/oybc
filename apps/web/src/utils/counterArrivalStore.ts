/**
 * counterArrivalStore.ts — Shared Counters P3 last-seen persistence (web).
 *
 * Per-board `taskId → displayed` snapshot, persisted in `localStorage`. This is
 * NOT synced schema — the arrival banner is a device-local "since you last
 * looked at THIS board" signal, so it deliberately lives outside the
 * board/task records that round-trip through Firestore. Mirrors the iOS
 * `CounterArrivalStore` (UserDefaults); both platforms key the entry by the
 * board id.
 *
 * All access is wrapped in try/catch — a disabled or full `localStorage` must
 * degrade to "no baseline" (⇒ first-view semantics, never a crash), because
 * the banner is strictly best-effort.
 */

/** Namespaced key prefix. The board id is appended verbatim. */
const KEY_PREFIX = 'oybc.counterArrivals.lastSeen.';

function keyFor(boardId: string): string {
  return `${KEY_PREFIX}${boardId}`;
}

/**
 * Read the last-seen snapshot for a board.
 *
 * @param boardId - The board whose snapshot to read.
 * @returns `taskId → displayed` map; `{}` when absent, malformed, or storage
 *   is unavailable (an absent entry is a first view — never an arrival).
 */
export function readLastSeen(boardId: string): Record<string, number> {
  try {
    const raw = localStorage.getItem(keyFor(boardId));
    if (!raw) return {};
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') return {};
    const out: Record<string, number> = {};
    for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof v === 'number' && Number.isFinite(v)) out[k] = v;
    }
    return out;
  } catch {
    return {};
  }
}

/**
 * Persist the last-seen snapshot for a board.
 *
 * @param boardId - The board whose snapshot to write.
 * @param snapshot - `taskId → displayed` map (from `snapshotCounterSquares`).
 */
export function writeLastSeen(boardId: string, snapshot: Record<string, number>): void {
  try {
    localStorage.setItem(keyFor(boardId), JSON.stringify(snapshot));
  } catch {
    // Ignore quota / disabled-storage errors — the banner is best-effort.
  }
}
