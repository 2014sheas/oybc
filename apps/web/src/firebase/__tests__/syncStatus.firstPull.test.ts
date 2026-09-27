import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  getSyncStatus,
  markFirstPullCompleted,
  recordSyncEvent,
  resetSyncStatus,
  subscribeSyncStatus,
} from '../syncStatus';

/**
 * Board Edit redesign slice 4 (D5) — the lazy auto-close pass
 * (`useBackstopAutoSeal`) waits on `firstPullCompleted`, which only a finished
 * `pullSync` pass sets. A single applied doc (`recordSyncEvent('pulled')`,
 * e.g. from an early `tasks` listener snapshot) must NOT satisfy it — the
 * `boards` collection might not have delivered a peer's Reopen yet.
 */
describe('syncStatus.firstPullCompleted', () => {
  afterEach(() => resetSyncStatus());

  it('stays false after individual pulled docs; flips only on markFirstPullCompleted', () => {
    recordSyncEvent('pulled');
    recordSyncEvent('pulled');
    expect(getSyncStatus().totalPulled).toBe(2);
    expect(getSyncStatus().firstPullCompleted).toBe(false);

    const listener = vi.fn();
    const unsubscribe = subscribeSyncStatus(listener);
    markFirstPullCompleted();
    markFirstPullCompleted(); // idempotent — no second notify
    unsubscribe();

    expect(getSyncStatus().firstPullCompleted).toBe(true);
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it('is cleared by resetSyncStatus (sign-out / account switch)', () => {
    markFirstPullCompleted();
    resetSyncStatus();
    expect(getSyncStatus().firstPullCompleted).toBe(false);
  });
});
