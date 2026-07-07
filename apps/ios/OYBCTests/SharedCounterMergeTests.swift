import XCTest
@testable import OYBC

/// Unit tests for `additiveMergeCount` / `needsAdditiveMerge` in
/// `SharedCounterMerge.swift` — Phase 4 conflict resolution for shared-counter
/// source tasks.
///
/// Parity target: `packages/shared/tests/algorithms/sharedCounterMerge.test.ts`.
/// Both suites cover the same vectors so any divergence between the Swift port
/// and the TypeScript source-of-truth is immediately caught.
///
/// Key invariants under test:
///   1. Both devices increment from the same base: merged = local + remote - common.
///   2. Only one device increments: the other's zero-delta contributes 0.
///   3. Three-way multi-device sequence: A +5, B +3 offline → 18.
///   4. Negative deltas (decrements) are respected.
///   5. Overshoot preserved — NO high-end clamp.
///   6. `lastSyncedCount == nil` → LWW fallback (no common ancestor).
///   7. `mergeApplied` reflects whether merge or LWW was used.
final class SharedCounterMergeTests: XCTestCase {

    // MARK: - Core additive-merge cases

    func test_bothDevicesIncrement_fromSameBase() {
        // Starting 10. A: +5 → 15. B: +3 → 13. Expected 18 (not 15 or 13).
        let result = additiveMergeCount(localCount: 15, remoteCount: 13, lastSyncedCount: 10)
        XCTAssertEqual(result.merged, 18)          // remote(13) + localDelta(15-10=5)
        XCTAssertTrue(result.mergeApplied)
    }

    func test_onlyLocalIncremented() {
        // lastSynced 10, local 15, remote 10 (unchanged). merged = 10 + 5 = 15.
        let result = additiveMergeCount(localCount: 15, remoteCount: 10, lastSyncedCount: 10)
        XCTAssertEqual(result.merged, 15)
        XCTAssertTrue(result.mergeApplied)
    }

    func test_onlyRemoteIncremented() {
        // lastSynced 10, local 10 (unchanged), remote 13. merged = 13 + 0 = 13.
        let result = additiveMergeCount(localCount: 10, remoteCount: 13, lastSyncedCount: 10)
        XCTAssertEqual(result.merged, 13)
        XCTAssertTrue(result.mergeApplied)
    }

    func test_threeWaySequence_AplusFive_BplusThree() {
        // Device B (local 13) merging after pulling Device A's push of 15.
        // localDelta = 13 - 10 = 3; merged = 15 + 3 = 18.
        let result = additiveMergeCount(localCount: 13, remoteCount: 15, lastSyncedCount: 10)
        XCTAssertEqual(result.merged, 18)
        XCTAssertTrue(result.mergeApplied)
    }

    func test_negativeLocalDelta_decrement() {
        // lastSynced 20, local 17 (-3), remote 25 (+5). merged = 25 + (17-20) = 22.
        let result = additiveMergeCount(localCount: 17, remoteCount: 25, lastSyncedCount: 20)
        XCTAssertEqual(result.merged, 22)
        XCTAssertTrue(result.mergeApplied)
    }

    func test_remoteDecrements_whileLocalIncrements() {
        // lastSynced 30, local 35 (+5), remote 27 (-3). merged = 27 + 5 = 32.
        let result = additiveMergeCount(localCount: 35, remoteCount: 27, lastSyncedCount: 30)
        XCTAssertEqual(result.merged, 32)
        XCTAssertTrue(result.mergeApplied)
    }

    func test_overshootPreserved_noHighEndClamp() {
        // lastSynced 90, local 115 (+25), remote 108 (+18). merged = 108 + 25 = 133.
        let result = additiveMergeCount(localCount: 115, remoteCount: 108, lastSyncedCount: 90)
        XCTAssertEqual(result.merged, 133)
        XCTAssertGreaterThan(result.merged, 100)   // NOT clamped to hypothetical maxCount 100
        XCTAssertTrue(result.mergeApplied)
    }

    // MARK: - nil lastSyncedCount → LWW fallback

    func test_nilLastSynced_lwwLocalWinsHigher() {
        // No common ancestor → LWW picks the higher value.
        let result = additiveMergeCount(localCount: 15, remoteCount: 13, lastSyncedCount: nil)
        XCTAssertEqual(result.merged, 15)          // local is higher
        XCTAssertFalse(result.mergeApplied)
    }

    func test_nilLastSynced_lwwRemoteWinsHigher() {
        let result = additiveMergeCount(localCount: 13, remoteCount: 15, lastSyncedCount: nil)
        XCTAssertEqual(result.merged, 15)          // remote is higher
        XCTAssertFalse(result.mergeApplied)
    }

    func test_nilLastSynced_tie() {
        let result = additiveMergeCount(localCount: 10, remoteCount: 10, lastSyncedCount: nil)
        XCTAssertEqual(result.merged, 10)
        XCTAssertFalse(result.mergeApplied)
    }

    // MARK: - mergeApplied flag

    func test_mergeApplied_trueWhenNonNilBase() {
        XCTAssertTrue(additiveMergeCount(localCount: 15, remoteCount: 13, lastSyncedCount: 10).mergeApplied)
    }

    func test_mergeApplied_falseWhenNilBase() {
        XCTAssertFalse(additiveMergeCount(localCount: 15, remoteCount: 13, lastSyncedCount: nil).mergeApplied)
    }

    // MARK: - Low-end clamp (defensive edge)

    func test_mergedClampedToZero_whenNegative() {
        // lastSynced 5, local 0 (-5), remote 0 (-5). raw = 0 + (0-5) = -5 → 0.
        let result = additiveMergeCount(localCount: 0, remoteCount: 0, lastSyncedCount: 5)
        XCTAssertEqual(result.merged, 0)
        XCTAssertTrue(result.mergeApplied)
    }

    func test_lwwFallback_alsoClampedToZero() {
        let result = additiveMergeCount(localCount: 0, remoteCount: 0, lastSyncedCount: nil)
        XCTAssertEqual(result.merged, 0)
        XCTAssertFalse(result.mergeApplied)
    }

    // MARK: - Identity cases

    func test_neitherDeviceChanged() {
        let result = additiveMergeCount(localCount: 10, remoteCount: 10, lastSyncedCount: 10)
        XCTAssertEqual(result.merged, 10)          // 10 + (10 - 10)
        XCTAssertTrue(result.mergeApplied)
    }

    func test_bothMadeSameIncrement() {
        // Both from 10, both +5 to 15. merged = 15 + (15 - 10) = 20.
        let result = additiveMergeCount(localCount: 15, remoteCount: 15, lastSyncedCount: 10)
        XCTAssertEqual(result.merged, 20)
        XCTAssertTrue(result.mergeApplied)
    }

    // MARK: - Large numbers

    func test_largePageReadingExample() {
        // Both start at 2000. A → 2200 (+200), B → 2150 (+150).
        // merged = 2150 + (2200 - 2000) = 2350.
        let result = additiveMergeCount(localCount: 2200, remoteCount: 2150, lastSyncedCount: 2000)
        XCTAssertEqual(result.merged, 2350)
        XCTAssertTrue(result.mergeApplied)
    }

    // MARK: - needsAdditiveMerge

    func test_needsMerge_bothChanged_true() {
        XCTAssertTrue(needsAdditiveMerge(localCount: 15, remoteCount: 13, lastSyncedCount: 10))
    }

    func test_needsMerge_onlyLocalChanged_false() {
        XCTAssertFalse(needsAdditiveMerge(localCount: 15, remoteCount: 10, lastSyncedCount: 10))
    }

    func test_needsMerge_onlyRemoteChanged_false() {
        XCTAssertFalse(needsAdditiveMerge(localCount: 10, remoteCount: 13, lastSyncedCount: 10))
    }

    func test_needsMerge_neitherChanged_false() {
        XCTAssertFalse(needsAdditiveMerge(localCount: 10, remoteCount: 10, lastSyncedCount: 10))
    }

    func test_needsMerge_nilBase_false() {
        XCTAssertFalse(needsAdditiveMerge(localCount: 15, remoteCount: 13, lastSyncedCount: nil))
    }
}
