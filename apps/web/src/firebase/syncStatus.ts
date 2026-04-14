/**
 * In-memory observability state for the sync layer.
 *
 * `pushSync` / `pullSync` already return per-call result objects, but
 * those are throwaway. This module accumulates them into a session-wide
 * snapshot so the UI (Profile "Last synced", playground SyncSimulation)
 * can show "is sync working right now."
 *
 * Mirrors the iOS `@Published` properties on `SyncService` — same
 * counters, same `lastEventAt`, same `lastError`. Reset to zero on
 * sign-out via `resetSyncStatus()` (called from `startSyncLoop`'s
 * cleanup).
 */

export interface SyncStatus {
  /** Cumulative successful pushes since last reset. */
  totalPushed: number;
  /** Cumulative successful pulls (listener apply OR safety-net pull). */
  totalPulled: number;
  /** Cumulative LWW conflicts where remote won. */
  totalConflicts: number;
  /** Cumulative push failures. */
  totalFailed: number;
  /** Most recent successful sync activity (push or pull); `null` until first event. */
  lastEventAt: Date | null;
  /** Most recent error, if any. Cleared on next successful event. */
  lastError: { message: string; at: Date } | null;
}

export type SyncEventKind = 'pushed' | 'pulled' | 'conflict' | 'failed';

const initialState: SyncStatus = {
  totalPushed: 0,
  totalPulled: 0,
  totalConflicts: 0,
  totalFailed: 0,
  lastEventAt: null,
  lastError: null,
};

let state: SyncStatus = { ...initialState };
const subscribers = new Set<(s: SyncStatus) => void>();

function notify(): void {
  for (const fn of subscribers) fn(state);
}

/** Snapshot of the current state. */
export function getSyncStatus(): SyncStatus {
  return state;
}

/**
 * Subscribe to state changes. Returns an unsubscribe function.
 *
 * Subscribers are notified after every `recordSyncEvent` /
 * `recordSyncError` / `resetSyncStatus` call.
 */
export function subscribeSyncStatus(fn: (s: SyncStatus) => void): () => void {
  subscribers.add(fn);
  return () => {
    subscribers.delete(fn);
  };
}

/**
 * Record a successful sync event, incrementing the matching counter
 * and advancing `lastEventAt`. Successful events also clear the
 * `lastError` slot so the UI doesn't show a stale error after recovery.
 */
export function recordSyncEvent(kind: SyncEventKind, at: Date = new Date()): void {
  const next: SyncStatus = { ...state, lastEventAt: at };
  switch (kind) {
    case 'pushed': next.totalPushed = state.totalPushed + 1; break;
    case 'pulled': next.totalPulled = state.totalPulled + 1; break;
    case 'conflict': next.totalConflicts = state.totalConflicts + 1; break;
    case 'failed':
      next.totalFailed = state.totalFailed + 1;
      // Don't advance `lastEventAt` for failures — keep that as the
      // last *successful* activity timestamp. The error slot covers it.
      next.lastEventAt = state.lastEventAt;
      break;
  }
  if (kind !== 'failed') next.lastError = null;
  state = next;
  notify();
}

/** Record an error message and timestamp. Doesn't increment any counter. */
export function recordSyncError(message: string, at: Date = new Date()): void {
  state = { ...state, lastError: { message, at } };
  notify();
}

/** Zero everything — called when the sync loop tears down. */
export function resetSyncStatus(): void {
  state = { ...initialState };
  notify();
}
