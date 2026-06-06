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
