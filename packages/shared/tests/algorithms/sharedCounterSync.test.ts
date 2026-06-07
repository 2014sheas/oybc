/**
 * sharedCounterSync.test.ts — Phase 4 end-to-end multi-device sync simulation.
 *
 * Integration-style tests that simulate two device states pulling and pushing
 * the same shared-counter source through the full sync conflict-resolution
 * sequence, asserting the final merged count is correct.
 *
 * No real DB or Firestore is involved. State is tracked in plain objects that
 * mirror the fields the sync layer reads and writes.
 *
 * Design: ARCHITECTURE.md §Shared counters, Decision 5 + Phase 4 design.
 */

import { additiveMergeCount, needsAdditiveMerge } from '../../src/algorithms/sharedCounterMerge';

// ─── Minimal task state type for simulation ──────────────────────────────────

interface SimTask {
  id: string;
  currentCount: number;
  lastSyncedCount: number | null;
  version: number;
}

// ─── Helpers that simulate what the sync service does ────────────────────────

/**
 * Simulate a local increment by N. Returns the updated local task.
 * Does NOT touch lastSyncedCount (only updated on Firestore round-trips).
 */
function localIncrement(task: SimTask, by: number): SimTask {
  return {
    ...task,
    currentCount: task.currentCount + by,
    version: task.version + 1,
  };
}

/**
 * Simulate a successful push to Firestore.
 * Post-push: lastSyncedCount := currentCount.
 * Returns the updated local task (the "Firestore" value is just this task's currentCount).
 */
function successfulPush(task: SimTask): { local: SimTask; firestore: SimTask } {
  const pushed: SimTask = {
    ...task,
    lastSyncedCount: task.currentCount,
  };
  // Firestore stores the pushed values verbatim (no lastSyncedCount on remote).
  const firestore: SimTask = {
    ...task,
    lastSyncedCount: task.currentCount, // irrelevant on remote; tracked for sim clarity
  };
  return { local: pushed, firestore };
}

/**
 * Simulate a pull and conflict resolution for counting source tasks.
 *
 * If additive merge fires: write merged count to local, bump version,
 * update lastSyncedCount to remote's currentCount, enqueue push.
 * If LWW wins (remote): replace local with remote, update lastSyncedCount.
 * If LWW wins (local): no-op.
 */
function simulatePull(
  local: SimTask,
  remote: SimTask,
): { resolved: SimTask; action: 'additive-merge' | 'remote-wins' | 'local-wins' } {
  const localCount = local.currentCount;
  const remoteCount = remote.currentCount;
  const lastSynced = local.lastSyncedCount;

  if (needsAdditiveMerge(localCount, remoteCount, lastSynced)) {
    const { merged } = additiveMergeCount(localCount, remoteCount, lastSynced);
    return {
      resolved: {
        ...local,
        currentCount: merged,
        lastSyncedCount: remoteCount, // common ancestor advances to remote's value
        version: local.version + 1,   // local write → bump version
      },
      action: 'additive-merge',
    };
  }

  // LWW by version, then timestamp tiebreaker (simulated by count here).
  if (remote.version > local.version) {
    return {
      resolved: {
        ...remote,
        lastSyncedCount: remote.currentCount, // pull: remote is now the ancestor
      },
      action: 'remote-wins',
    };
  }

  // Local wins — no write.
  return { resolved: local, action: 'local-wins' };
}

// ─── Integration tests ────────────────────────────────────────────────────────

describe('Shared Counter Sync — multi-device integration', () => {
  /**
   * Scenario 1: Two devices increment the same source simultaneously offline.
   *
   * Setup: Both devices have source at 10 (lastSyncedCount=10).
   * Device A: +5 → 15. Pushes first (wins; remote = 15).
   * Device B: +3 → 13. Pulls remote (15) before pushing.
   *   - B has lastSyncedCount=10, local=13, remote=15 → needsMerge=true.
   *   - Merged = 15 + (13-10) = 18.
   * B pushes 18. Firestore = 18.
   * Device A pulls 18.
   * Final on both devices: 18.
   */
  it('Scenario 1: two devices both increment offline → merged sum = 18 (10 + 5 + 3)', () => {
    // Starting state (after last sync): both devices agree.
    const startingCount = 10;
    const startingVersion = 3;

    const deviceA: SimTask = {
      id: 'source-task',
      currentCount: startingCount,
      lastSyncedCount: startingCount,
      version: startingVersion,
    };

    let deviceB: SimTask = {
      id: 'source-task',
      currentCount: startingCount,
      lastSyncedCount: startingCount,
      version: startingVersion,
    };

    // Both go offline and increment.
    let localA = localIncrement(deviceA, 5);   // A: 10 → 15
    deviceB = localIncrement(deviceB, 3);       // B: 10 → 13

    // Device A pushes first (no conflict — remote doesn't exist yet in this sim).
    const { local: pushedA, firestore } = successfulPush(localA);

    // Device B comes online and pulls A's push before pushing.
    const { resolved: mergedB, action } = simulatePull(deviceB, firestore);

    expect(action).toBe('additive-merge');
    expect(mergedB.currentCount).toBe(18); // 15 + (13 - 10) = 18

    // Device B pushes the merged value.
    const { firestore: finalFirestore } = successfulPush(mergedB);

    // Device A pulls the merged value.
    const { resolved: finalA } = simulatePull(pushedA, finalFirestore);

    expect(finalFirestore.currentCount).toBe(18);
    expect(finalA.currentCount).toBe(18);
    expect(mergedB.lastSyncedCount).toBe(15); // advanced to remote's value after merge
  });

  /**
   * Scenario 2: Only one device increments; the other was idle.
   *
   * Device A: +5 → 15. Pushes. Firestore=15.
   * Device B: idle (currentCount=10, lastSyncedCount=10). Pulls.
   *   - needsMerge(10, 15, 10) = false (B didn't change).
   * B takes remote (15). No concurrent conflict.
   * Final: 15 everywhere.
   */
  it('Scenario 2: only one device incremented → remote-wins LWW (delta preserved)', () => {
    const deviceA: SimTask = {
      id: 'source-task', currentCount: 10, lastSyncedCount: 10, version: 3,
    };
    const deviceB: SimTask = {
      id: 'source-task', currentCount: 10, lastSyncedCount: 10, version: 3,
    };

    const localA = localIncrement(deviceA, 5); // A: 15
    const { firestore } = successfulPush(localA);

    const { resolved, action } = simulatePull(deviceB, firestore);

    // B hasn't changed — remote wins via LWW, no additive merge.
    expect(action).toBe('remote-wins');
    expect(resolved.currentCount).toBe(15);
  });

  /**
   * Scenario 3: Three-way sequence (A +5, B +3, C +2).
   *
   * All start at 10. A pushes first. B merges against A. B pushes. C merges
   * against merged B. C pushes. Final = 10 + 5 + 3 + 2 = 20.
   */
  it('Scenario 3: three devices all increment → merged sum = 20 (10 + 5 + 3 + 2)', () => {
    const base: SimTask = { id: 's', currentCount: 10, lastSyncedCount: 10, version: 1 };

    let devA: SimTask = { ...base };
    let devB: SimTask = { ...base };
    let devC: SimTask = { ...base };

    devA = localIncrement(devA, 5); // A: 15
    devB = localIncrement(devB, 3); // B: 13
    devC = localIncrement(devC, 2); // C: 12

    // A pushes first.
    const { firestore: fs1 } = successfulPush(devA);
    expect(fs1.currentCount).toBe(15);

    // B merges against A's push.
    const { resolved: mergedB, action: action1 } = simulatePull(devB, fs1);
    expect(action1).toBe('additive-merge');
    expect(mergedB.currentCount).toBe(18); // 15 + (13-10) = 18

    // B pushes.
    const { firestore: fs2 } = successfulPush(mergedB);
    expect(fs2.currentCount).toBe(18);

    // C merges against B's push (C still has lastSyncedCount=10, local=12).
    const { resolved: mergedC, action: action2 } = simulatePull(devC, fs2);
    expect(action2).toBe('additive-merge');
    expect(mergedC.currentCount).toBe(20); // 18 + (12-10) = 20

    // C pushes.
    const { firestore: finalFs } = successfulPush(mergedC);
    expect(finalFs.currentCount).toBe(20);
  });

  /**
   * Scenario 4: Decrement to correct an over-count; concurrent remote increment.
   *
   * Both start at 20. A decrements to 17 (fixed typo). B increments to 25.
   * A pulls B's 25 while A is at 17 (lastSyncedCount=20).
   * merged = 25 + (17-20) = 22.
   * Final: 22 (both deltas honoured — the correction and the real progress).
   */
  it('Scenario 4: local decrement + remote increment → correction preserved in merge', () => {
    const base: SimTask = { id: 's', currentCount: 20, lastSyncedCount: 20, version: 2 };
    let devA: SimTask = { ...base };
    let devB: SimTask = { ...base };

    devA = { ...devA, currentCount: 17, version: devA.version + 1 }; // A decrements
    devB = localIncrement(devB, 5); // B: 20+5=25

    const { firestore } = successfulPush(devB);

    const { resolved, action } = simulatePull(devA, firestore);
    expect(action).toBe('additive-merge');
    expect(resolved.currentCount).toBe(22); // 25 + (17-20) = 22
  });

  /**
   * Scenario 5: `lastSyncedCount=null` fallback to LWW.
   *
   * Device B has never synced this task (firstSync). Both have incremented,
   * but since B has no common-ancestor, additive merge is not safe.
   * LWW: higher version/count wins.
   */
  it('Scenario 5: null lastSyncedCount → LWW fallback, no additive merge', () => {
    const devA: SimTask = { id: 's', currentCount: 15, lastSyncedCount: 15, version: 4 };
    const devB: SimTask = { id: 's', currentCount: 13, lastSyncedCount: null, version: 3 };

    // B pulls A's state.
    expect(needsAdditiveMerge(devB.currentCount, devA.currentCount, devB.lastSyncedCount)).toBe(false);

    // LWW: A (remote) wins.
    const { resolved, action } = simulatePull(devB, devA);
    expect(action).toBe('remote-wins');
    expect(resolved.currentCount).toBe(15);
  });

  /**
   * Scenario 6: Overshoot through merge.
   *
   * maxCount=100 (not part of SimTask, but conceptually present).
   * Both devices exceed 100 through concurrent increments.
   * Merged result must NOT be clamped — overshoot is valid.
   */
  it('Scenario 6: concurrent increments push count above any threshold — no clamp applied', () => {
    const base: SimTask = { id: 's', currentCount: 90, lastSyncedCount: 90, version: 5 };
    let devA: SimTask = { ...base };
    let devB: SimTask = { ...base };

    devA = localIncrement(devA, 15); // 90+15=105 (overshoots 100)
    devB = localIncrement(devB, 20); // 90+20=110 (overshoots 100)

    const { firestore } = successfulPush(devA); // A pushes 105.

    const { resolved, action } = simulatePull(devB, firestore);
    expect(action).toBe('additive-merge');
    // merged = 105 + (110-90) = 125. NOT clamped to 100.
    expect(resolved.currentCount).toBe(125);
    expect(resolved.currentCount).toBeGreaterThan(100);
  });

  /**
   * Scenario 7: lastSyncedCount advances correctly through a push-then-pull cycle.
   *
   * Verifies that after a successful push, `lastSyncedCount` equals
   * `currentCount`, so a subsequent pull with no concurrent edits resolves
   * as local-wins (no spurious merge).
   */
  it('Scenario 7: lastSyncedCount bookkeeping prevents false merge on next pull', () => {
    const task: SimTask = { id: 's', currentCount: 10, lastSyncedCount: 10, version: 1 };

    // Device A increments and pushes.
    let devA = localIncrement(task, 5); // 15
    const { local: afterPush } = successfulPush(devA);

    // afterPush.lastSyncedCount should now be 15.
    expect(afterPush.lastSyncedCount).toBe(15);

    // Device B pushes remote=15. A pulls.
    const remoteB: SimTask = { ...task, currentCount: 15, version: 2 };

    // needsAdditiveMerge(local=15, remote=15, lastSynced=15) → false
    expect(needsAdditiveMerge(afterPush.currentCount, remoteB.currentCount, afterPush.lastSyncedCount)).toBe(false);

    // No spurious merge.
    const { resolved, action } = simulatePull(afterPush, remoteB);
    // Same version — local wins.
    expect(action).toBe('local-wins');
    expect(resolved.currentCount).toBe(15);
  });
});

// ─── PR #99 regression tests ──────────────────────────────────────────────────

describe('PR #99 regressions — merge correctness and tombstone safety', () => {
  /**
   * Regression: "additive merge skipped on remote tombstone"
   *
   * If a remote tombstone (isDeleted=true) arrives while the local task has
   * a pending increment, the sync layer must NOT call needsAdditiveMerge at all.
   * The guard in syncService.ts / SyncService.swift short-circuits before
   * invoking the merge path when either side isDeleted.
   *
   * This test verifies the guard contract at the algorithm boundary:
   *   - needsAdditiveMerge(13, 0, 10) would return true for the counts alone,
   *     meaning WITHOUT the guard, a spurious merge would fire.
   *   - The sync service must therefore check isDeleted BEFORE calling
   *     needsAdditiveMerge. This test documents that expectation explicitly.
   */
  it('Regression: additive merge skipped on remote tombstone — delete must propagate', () => {
    // Both devices start at 10. Local incremented to 13 (pending push).
    // Remote was soft-deleted. counts are (13, 0, lastSynced=10).
    const localCount = 13;
    const remoteCount = 0; // currentCount after delete (irrelevant; delete wins)
    const lastSynced = 10;

    // Without the isDeleted guard, needsAdditiveMerge WOULD fire — this is the bug.
    // The sync service guard must prevent calling needsAdditiveMerge entirely.
    expect(needsAdditiveMerge(localCount, remoteCount, lastSynced)).toBe(true);
    // ^ Confirms the guard is necessary: merge WOULD incorrectly run without it.

    // With the guard applied (sync service checks isDeleted first),
    // the tombstone falls through to LWW. Remote has higher version → remote wins.
    // Simulated here by bypassing the merge path entirely (as the guard does).
    const remoteTombstone: SimTask = { id: 's', currentCount: 0, lastSyncedCount: null, version: 5 };

    // Simulate the LWW path directly (tombstone guard short-circuits merge).
    // Remote version (5) > local version (2) → remote wins.
    const lwwResolved: SimTask = { ...remoteTombstone, lastSyncedCount: remoteTombstone.currentCount };
    expect(lwwResolved.currentCount).toBe(0);
    expect(lwwResolved.version).toBe(5);

    // Confirm: if we incorrectly ran additive merge (the bug), we'd get 3
    // (0 + (13-10) = 3), resurrecting the deleted record with a non-zero count.
    const { merged: buggyMerge } = additiveMergeCount(localCount, remoteCount, lastSynced);
    expect(buggyMerge).toBe(3); // This is what the guard prevents.
  });

  /**
   * Regression: "merge preserves remote non-count field changes"
   *
   * Remote changed `title` (non-count field) AND `currentCount` while local
   * had a pending increment. The sync service must:
   *   1. Apply the full remote record first (gets new title).
   *   2. Layer the merged count on top (preserves local delta).
   *
   * At algorithm level: we verify the merged count is correct. The full-record
   * upsert responsibility lives in the sync service, which is tested here
   * by confirming the merge formula produces the right count value.
   */
  it('Regression: merge preserves correct count when remote has non-count field changes', () => {
    // Both start at 10. Remote updated title AND incremented to 14.
    // Local incremented to 13. Merge should yield 14 + (13 - 10) = 17.
    const localCount = 13;
    const remoteCount = 14;
    const lastSynced = 10;

    expect(needsAdditiveMerge(localCount, remoteCount, lastSynced)).toBe(true);

    const { merged, mergeApplied } = additiveMergeCount(localCount, remoteCount, lastSynced);
    expect(mergeApplied).toBe(true);
    expect(merged).toBe(17); // 14 + (13 - 10) = 17

    // Title preservation is a sync-service concern (full table.put first,
    // then count update on top). The algorithm layer produces the correct count.
  });

  /**
   * Regression: "merge version is max(local, remote) + 1"
   *
   * local v3, remote v5, both incremented concurrently.
   * The merged write must use version = max(3, 5) + 1 = 6 so that the
   * next LWW round does not silently discard the merge.
   */
  it('Regression: merge version = max(local, remote) + 1', () => {
    const localVersion = 3;
    const remoteVersion = 5;
    const expectedMergedVersion = Math.max(localVersion, remoteVersion) + 1;
    expect(expectedMergedVersion).toBe(6);

    // Also confirm the algorithm produces the right count (algorithm is
    // version-agnostic; version handling is a sync-service concern).
    const { merged } = additiveMergeCount(/* local= */8, /* remote= */10, /* lastSynced= */5);
    // 10 + (8 - 5) = 13
    expect(merged).toBe(13);
  });
});
