import XCTest
@testable import OYBC

/// Tests for the iOS `SyncRetry` enum — the Swift mirror of
/// `packages/shared/src/constants/syncRetry.ts`. The two need to stay in
/// lockstep; if either drifts, real failures stop being retried at the
/// expected cadence.
final class SyncRetryTests: XCTestCase {

    // MARK: - Schedule shape

    func testBackoffScheduleLengthMatchesMaxRetries() {
        XCTAssertEqual(
            SyncRetry.backoffMs.count,
            SyncRetry.maxRetries,
            "Backoff schedule length must match maxRetries so the cap aligns with the longest-window retry."
        )
    }

    func testBackoffScheduleIsMonotonicallyNonDecreasing() {
        for i in 1..<SyncRetry.backoffMs.count {
            XCTAssertGreaterThanOrEqual(
                SyncRetry.backoffMs[i],
                SyncRetry.backoffMs[i - 1],
                "Backoff[\(i)] must be >= Backoff[\(i - 1)] for exponential semantics."
            )
        }
    }

    // MARK: - Eligibility windows

    /// A reference "now" used so tests don't depend on wall-clock drift.
    private let now: Int = 1_000_000_000_000

    func testNullLastAttemptIsImmediatelyEligible() {
        XCTAssertTrue(
            SyncRetry.isFailedItemEligibleForRetry(retryCount: 1, lastAttemptAtMs: nil, nowMs: now),
            "An item with no recorded last-attempt timestamp should be eligible (defensive — handles legacy / direct-write rows)."
        )
    }

    func testNotEligibleBeforeBackoffWindow() {
        let oneSecondAgo = now - 1_000 // well under the 30s first-retry window
        XCTAssertFalse(
            SyncRetry.isFailedItemEligibleForRetry(retryCount: 1, lastAttemptAtMs: oneSecondAgo, nowMs: now),
            "Item attempted 1s ago should NOT be eligible under the 30s window."
        )
    }

    func testEligibleAfterBackoffWindow() {
        let thirtyOneSecondsAgo = now - 31_000
        XCTAssertTrue(
            SyncRetry.isFailedItemEligibleForRetry(retryCount: 1, lastAttemptAtMs: thirtyOneSecondsAgo, nowMs: now),
            "Item attempted 31s ago should be eligible under the 30s window."
        )
    }

    func testHigherRetryCountUsesLongerWindow() {
        // 31s elapsed: enough for retryCount=1 (30s window) but not retryCount=2 (2 min window).
        let thirtyOneSecondsAgo = now - 31_000
        XCTAssertTrue(
            SyncRetry.isFailedItemEligibleForRetry(retryCount: 1, lastAttemptAtMs: thirtyOneSecondsAgo, nowMs: now)
        )
        XCTAssertFalse(
            SyncRetry.isFailedItemEligibleForRetry(retryCount: 2, lastAttemptAtMs: thirtyOneSecondsAgo, nowMs: now)
        )
    }

    func testRetryCountAboveScheduleClampsToCapInterval() {
        guard let cap = SyncRetry.backoffMs.last else {
            XCTFail("Backoff schedule unexpectedly empty")
            return
        }
        let justBeforeCap = now - (cap - 1)
        let justAfterCap = now - (cap + 1)
        XCTAssertFalse(
            SyncRetry.isFailedItemEligibleForRetry(retryCount: 99, lastAttemptAtMs: justBeforeCap, nowMs: now),
            "retryCount above the schedule should clamp to the cap window — not yet elapsed."
        )
        XCTAssertTrue(
            SyncRetry.isFailedItemEligibleForRetry(retryCount: 99, lastAttemptAtMs: justAfterCap, nowMs: now),
            "retryCount above the schedule should clamp to the cap window — elapsed."
        )
    }

    func testRetryCountZeroBehavesLikeFirstRetry() {
        // Defensive — items written by older code or direct DB pokes might
        // arrive with retryCount 0; the eligibility check shouldn't crash.
        let thirtyOneSecondsAgo = now - 31_000
        XCTAssertTrue(
            SyncRetry.isFailedItemEligibleForRetry(retryCount: 0, lastAttemptAtMs: thirtyOneSecondsAgo, nowMs: now)
        )
    }
}
