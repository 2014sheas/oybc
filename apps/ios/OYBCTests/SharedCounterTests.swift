import XCTest
@testable import OYBC

/// Unit tests for `deriveDisplayedCount(_:source:)` in `SharedCounter.swift`.
///
/// Parity target: `packages/shared/tests/algorithms/sharedCounter.test.ts`.
/// Both test suites must cover the same 6+ invariant cases so divergence
/// between the Swift port and the TypeScript source-of-truth is immediately
/// caught.
///
/// Key invariants under test:
///   1. LOW-END CLAMP: `displayed` is always >= 0.
///   2. NO HIGH-END CLAMP: source overshooting `maxCount` produces
///      `displayed = sourceCount` (not clamped to maxCount). There is NO
///      `min(displayed, maxCount)` inside `deriveDisplayedCount`.
///   3. `isCompleted` is a snapshot: true when `displayed >= maxCount`.
final class SharedCounterTests: XCTestCase {

    // MARK: - Inherit baseline (baseline = 0)

    func test_inheritBaseline_sourceBelow_notCompleted() {
        // baseline = 0, source < maxCount → displayed = source, not completed.
        let result = deriveDisplayedCount(
            derivedBaseline: 0,
            derivedMaxCount: 100,
            sourceCurrentCount: 42
        )
        XCTAssertEqual(result.displayed, 42)
        XCTAssertFalse(result.isCompleted)
    }

    func test_inheritBaseline_sourceAtThreshold_completed() {
        // baseline = 0, source == maxCount → displayed = source, completed.
        let result = deriveDisplayedCount(
            derivedBaseline: 0,
            derivedMaxCount: 100,
            sourceCurrentCount: 100
        )
        XCTAssertEqual(result.displayed, 100)
        XCTAssertTrue(result.isCompleted)
    }

    /// NO HIGH-END CLAMP — critical Phase 0 invariant.
    /// source.currentCount overshoots maxCount → displayed must be the raw
    /// overshoot, NOT clamped to maxCount. isCompleted stays true.
    func test_inheritBaseline_sourceOvershoot_noHighClamp() {
        let result = deriveDisplayedCount(
            derivedBaseline: 0,
            derivedMaxCount: 5000,
            sourceCurrentCount: 5500
        )
        // Must NOT be clamped to 5000.
        XCTAssertEqual(result.displayed, 5500,
            "No high-end clamp: overshoot must appear as-is in displayed.")
        XCTAssertTrue(result.isCompleted)
    }

    // MARK: - Start-from-zero baseline (baseline = source count at link time)

    func test_nonZeroBaseline_sourceAboveBaseline_derivedProgress() {
        // User had read 200 pages at link time; derived task targets 50 more.
        let result = deriveDisplayedCount(
            derivedBaseline: 200,
            derivedMaxCount: 50,
            sourceCurrentCount: 230
        )
        XCTAssertEqual(result.displayed, 30) // 230 - 200
        XCTAssertFalse(result.isCompleted)
    }

    func test_nonZeroBaseline_sourceAtThreshold_completed() {
        let result = deriveDisplayedCount(
            derivedBaseline: 200,
            derivedMaxCount: 50,
            sourceCurrentCount: 250
        )
        XCTAssertEqual(result.displayed, 50)
        XCTAssertTrue(result.isCompleted)
    }

    // MARK: - Low-end clamp (defensive edge)

    /// Shouldn't happen in production (a baseline is set from the source count at
    /// link time), but the math must defensively return 0 rather than a negative.
    func test_baselineAboveSource_lowEndClamp() {
        let result = deriveDisplayedCount(
            derivedBaseline: 100,
            derivedMaxCount: 50,
            sourceCurrentCount: 80 // dropped below baseline
        )
        XCTAssertEqual(result.displayed, 0, // max(0, 80 - 100) = 0
            "Displayed must never go below 0 (low-end clamp only).")
        XCTAssertFalse(result.isCompleted)
    }

    // MARK: - Zero maxCount

    func test_zeroMaxCount_immediatelyCompleted() {
        // A threshold of 0 means the task is instantly satisfied.
        // "Read 0 pages" is always done.
        let result = deriveDisplayedCount(
            derivedBaseline: 0,
            derivedMaxCount: 0,
            sourceCurrentCount: 0
        )
        XCTAssertEqual(result.displayed, 0)
        XCTAssertTrue(result.isCompleted, // 0 >= 0
            "maxCount = 0 → isCompleted must be true immediately.")
    }

    // MARK: - Additional coverage

    func test_zeroEverything_notCompleted_atPositiveMax() {
        let result = deriveDisplayedCount(
            derivedBaseline: 0,
            derivedMaxCount: 10,
            sourceCurrentCount: 0
        )
        XCTAssertEqual(result.displayed, 0)
        XCTAssertFalse(result.isCompleted)
    }

    func test_largeOvershoot_noClamp() {
        // Verify no hidden clamp for very large overshoots.
        let result = deriveDisplayedCount(
            derivedBaseline: 0,
            derivedMaxCount: 100,
            sourceCurrentCount: 999
        )
        XCTAssertEqual(result.displayed, 999)
        XCTAssertTrue(result.isCompleted)
    }
}

/// Unit tests for `propagateIncrement(sourceAfterCurrentCount:linkedTasks:)`.
///
/// Parity target: the `propagateIncrement` describe-block in
/// `packages/shared/tests/algorithms/sharedCounter.test.ts`. Results are
/// returned in the same order as `linkedTasks`, so cases index directly rather
/// than searching by id.
final class PropagateIncrementTests: XCTestCase {

    // MARK: - Two linked tasks with different baselines

    func test_twoLinkedTasks_deriveIndependently() {
        // Source: currentCount = 105 (incremented from 100 by 5).
        let results = propagateIncrement(
            sourceAfterCurrentCount: 105,
            linkedTasks: [
                PropagateIncrementLinkedTask(id: "a", baseline: 0, maxCount: 200, isCompleted: false),
                PropagateIncrementLinkedTask(id: "b", baseline: 100, maxCount: 10, isCompleted: false),
            ]
        )
        XCTAssertEqual(results.count, 2)

        let a = results[0]
        XCTAssertEqual(a.taskId, "a")
        XCTAssertEqual(a.displayed, 105)          // 105 - 0
        XCTAssertFalse(a.newIsCompleted)          // 105 < 200
        XCTAssertEqual(a.newCurrentCount, 105)

        let b = results[1]
        XCTAssertEqual(b.taskId, "b")
        XCTAssertEqual(b.displayed, 5)            // 105 - 100
        XCTAssertFalse(b.newIsCompleted)          // 5 < 10
        XCTAssertEqual(b.newCurrentCount, 105)
    }

    // MARK: - Source overshoots its own maxCount

    func test_sourceOvershoot_noClampOnCurrentCount() {
        // Source received the already-incremented value 75 (maxCount was 50);
        // no clamping happens here.
        let results = propagateIncrement(
            sourceAfterCurrentCount: 75,
            linkedTasks: [
                PropagateIncrementLinkedTask(id: "x", baseline: 0, maxCount: 50, isCompleted: true),
            ]
        )
        let x = results[0]
        XCTAssertEqual(x.newCurrentCount, 75)     // raw source value, never clamped to 50
        XCTAssertEqual(x.displayed, 75)           // 75 - 0, no high-end clamp
        XCTAssertTrue(x.newIsCompleted)           // latch preserves true
    }

    // MARK: - Linked task completes before / after source

    func test_lowMaxCount_completesBeforeSource() {
        // Source at 30 (below its own maxCount 100). Linked maxCount 20.
        let results = propagateIncrement(
            sourceAfterCurrentCount: 30,
            linkedTasks: [
                PropagateIncrementLinkedTask(id: "early", baseline: 0, maxCount: 20, isCompleted: false),
            ]
        )
        let early = results[0]
        XCTAssertEqual(early.displayed, 30)
        XCTAssertTrue(early.newIsCompleted)       // 30 >= 20
    }

    func test_highMaxCount_staysIncomplete() {
        // Source at 100 (its own maxCount). Linked maxCount 200.
        let results = propagateIncrement(
            sourceAfterCurrentCount: 100,
            linkedTasks: [
                PropagateIncrementLinkedTask(id: "late", baseline: 0, maxCount: 200, isCompleted: false),
            ]
        )
        let late = results[0]
        XCTAssertEqual(late.displayed, 100)
        XCTAssertFalse(late.newIsCompleted)       // 100 < 200
    }

    // MARK: - One-way latch

    func test_oneWayLatch_staysCompleted() {
        // Defensive edge: baseline 50, source 30 → displayed = max(0, 30-50) = 0
        // → derived false, but the task was already latched → stays true.
        let results = propagateIncrement(
            sourceAfterCurrentCount: 30,
            linkedTasks: [
                PropagateIncrementLinkedTask(id: "latched", baseline: 50, maxCount: 10, isCompleted: true),
            ]
        )
        XCTAssertTrue(results[0].newIsCompleted)  // latch holds
    }

    // MARK: - Empty linked set

    func test_noLinkedTasks_returnsEmpty() {
        let results = propagateIncrement(sourceAfterCurrentCount: 42, linkedTasks: [])
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Multiple sequential increments accumulate

    func test_multipleSequentialIncrements_accumulate() {
        var state = PropagateIncrementLinkedTask(id: "acc", baseline: 0, maxCount: 5, isCompleted: false)

        // Simulate 3 increments: source 1 → 2 → 3.
        for i in 1...3 {
            let result = propagateIncrement(sourceAfterCurrentCount: i, linkedTasks: [state])[0]
            state = PropagateIncrementLinkedTask(
                id: state.id, baseline: state.baseline, maxCount: state.maxCount,
                isCompleted: result.newIsCompleted
            )
        }
        XCTAssertFalse(state.isCompleted)         // displayed 3 < 5

        // Two more: source 4, 5.
        for i in 4...5 {
            let result = propagateIncrement(sourceAfterCurrentCount: i, linkedTasks: [state])[0]
            state = PropagateIncrementLinkedTask(
                id: state.id, baseline: state.baseline, maxCount: state.maxCount,
                isCompleted: result.newIsCompleted
            )
        }
        XCTAssertTrue(state.isCompleted)          // source 5 == maxCount 5

        // One more overshoot: source 6.
        let overshoot = propagateIncrement(sourceAfterCurrentCount: 6, linkedTasks: [state])[0]
        XCTAssertEqual(overshoot.newCurrentCount, 6)  // no clamp
        XCTAssertTrue(overshoot.newIsCompleted)       // latch holds
        XCTAssertEqual(overshoot.displayed, 6)        // raw overshoot
    }

    // MARK: - PR #97 regressions

    func test_pr97_linkedDisplayIsBaselineAdjusted_notRawCount() {
        // Source incremented to 150. Linked baseline 100, maxCount 80.
        // displayed = max(0, 150 - 100) = 50, NOT the raw 150.
        let result = propagateIncrement(
            sourceAfterCurrentCount: 150,
            linkedTasks: [
                PropagateIncrementLinkedTask(id: "linked", baseline: 100, maxCount: 80, isCompleted: false),
            ]
        )[0]
        XCTAssertEqual(result.newCurrentCount, 150)   // mirrors source — UI must NOT show this
        XCTAssertEqual(result.displayed, 50)          // baseline-adjusted value to render
        XCTAssertNotEqual(result.displayed, result.newCurrentCount)
    }

    func test_pr97_overshootPreservesFullDisplayed_noHighClamp() {
        // Source at 5500 (overshooting its own maxCount 5000). Linked
        // baseline 0, maxCount 5000. displayed = 5500, latched true.
        let result = propagateIncrement(
            sourceAfterCurrentCount: 5500,
            linkedTasks: [
                PropagateIncrementLinkedTask(id: "overshoot", baseline: 0, maxCount: 5000, isCompleted: true),
            ]
        )[0]
        XCTAssertEqual(result.displayed, 5500)        // raw overshoot, not clamped to 5000
        XCTAssertEqual(result.newCurrentCount, 5500)
        XCTAssertTrue(result.newIsCompleted)          // latch holds
    }

    // MARK: - 1:N fan-out

    func test_oneToN_fanOut_allUpdate() {
        let results = propagateIncrement(
            sourceAfterCurrentCount: 10,
            linkedTasks: [
                PropagateIncrementLinkedTask(id: "n1", baseline: 0, maxCount: 5, isCompleted: false),
                PropagateIncrementLinkedTask(id: "n2", baseline: 0, maxCount: 10, isCompleted: false),
                PropagateIncrementLinkedTask(id: "n3", baseline: 0, maxCount: 20, isCompleted: false),
            ]
        )
        XCTAssertEqual(results.count, 3)

        XCTAssertEqual(results[0].taskId, "n1")
        XCTAssertTrue(results[0].newIsCompleted)      // 10 >= 5
        XCTAssertEqual(results[0].displayed, 10)      // no clamp

        XCTAssertEqual(results[1].taskId, "n2")
        XCTAssertTrue(results[1].newIsCompleted)      // 10 >= 10
        XCTAssertEqual(results[1].displayed, 10)

        XCTAssertEqual(results[2].taskId, "n3")
        XCTAssertFalse(results[2].newIsCompleted)     // 10 < 20
        XCTAssertEqual(results[2].displayed, 10)
    }
}
