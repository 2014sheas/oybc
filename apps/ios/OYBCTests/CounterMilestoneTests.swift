import XCTest
@testable import OYBC

/// Unit tests for `nextCounterMilestone`/`counterMilestoneProgress` in
/// `Helpers/CounterMilestone.swift`.
///
/// Swift port of `packages/shared/tests/algorithms/counterMilestone.test.ts`
/// — mirrors every case so drift between the TS source of truth and the
/// Swift port is caught immediately.
final class CounterMilestoneTests: XCTestCase {

    // MARK: - nextCounterMilestone

    func test_returnsFirstFixedStepForZero() {
        XCTAssertEqual(nextCounterMilestone(0), 100)
    }

    func test_returnsNextFixedStepWhenExactlyOnAStep() {
        XCTAssertEqual(nextCounterMilestone(100), 250)
        XCTAssertEqual(nextCounterMilestone(1_000), 2_500)
    }

    func test_returnsNextFixedStepBetweenTwoSteps() {
        XCTAssertEqual(nextCounterMilestone(150), 250)
        XCTAssertEqual(nextCounterMilestone(999), 1_000)
    }

    func test_walksEveryFixedStepBoundary() {
        XCTAssertEqual(nextCounterMilestone(99), 100)
        XCTAssertEqual(nextCounterMilestone(249), 250)
        XCTAssertEqual(nextCounterMilestone(499), 500)
        XCTAssertEqual(nextCounterMilestone(2_499), 2_500)
        XCTAssertEqual(nextCounterMilestone(4_999), 5_000)
        XCTAssertEqual(nextCounterMilestone(9_999), 10_000)
        XCTAssertEqual(nextCounterMilestone(24_999), 25_000)
        XCTAssertEqual(nextCounterMilestone(49_999), 50_000)
        XCTAssertEqual(nextCounterMilestone(99_999), 100_000)
    }

    func test_fallsBackToNextMultipleOf10kPastTopStep() {
        XCTAssertEqual(nextCounterMilestone(100_000), 110_000)
        XCTAssertEqual(nextCounterMilestone(100_001), 110_000)
        XCTAssertEqual(nextCounterMilestone(109_999), 110_000)
        XCTAssertEqual(nextCounterMilestone(110_000), 120_000)
    }

    func test_matchesCeilFallbackFormulaForLargeValues() {
        XCTAssertEqual(nextCounterMilestone(1_234_567), 1_240_000)
    }

    // MARK: - counterMilestoneProgress

    func test_computesNextRemainingFractionForMidRangeValue() {
        let result = counterMilestoneProgress(150)
        XCTAssertEqual(result.next, 250)
        XCTAssertEqual(result.remaining, 100)
        XCTAssertEqual(result.fraction, 0.6, accuracy: 0.0001)
    }

    func test_startsAtFractionZeroForFreshCounter() {
        let result = counterMilestoneProgress(0)
        XCTAssertEqual(result.next, 100)
        XCTAssertEqual(result.remaining, 100)
        XCTAssertEqual(result.fraction, 0)
    }

    func test_clampsFractionAndRemainingStaysAccurateMidFixedStep() {
        let result = counterMilestoneProgress(99)
        XCTAssertEqual(result.next, 100)
        XCTAssertEqual(result.remaining, 1)
        XCTAssertEqual(result.fraction, 0.99, accuracy: 0.0001)
    }

    func test_handlesPostTopStepFallbackRange() {
        let result = counterMilestoneProgress(100_000)
        XCTAssertEqual(result.next, 110_000)
        XCTAssertEqual(result.remaining, 10_000)
        XCTAssertEqual(result.fraction, 100_000.0 / 110_000.0, accuracy: 0.0001)
    }
}
