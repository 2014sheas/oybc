import XCTest
@testable import OYBC

/// Unit tests for `TaskExpiry.isTaskExpired` / `TaskExpiry.parseTaskEndDate`.
///
/// Parity target: `packages/shared/tests/algorithms/taskExpiry.test.ts`.
/// Both suites cover the same vectors so any divergence between the Swift
/// port and the TypeScript source-of-truth (`taskExpiry.ts`) is immediately
/// caught. Extracted from an inline implementation on `TasksTabViewModel`
/// (issue #246 part 2); `TasksTabViewModel.isTaskExpired` now forwards here.
final class TaskExpiryTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTask(endDate: String? = nil) -> Task {
        Task(
            id: "00000000-0000-0000-0000-000000000001",
            userId: "u1",
            title: "sample",
            type: .normal,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: "2026-05-01T00:00:00.000Z",
            updatedAt: "2026-05-01T00:00:00.000Z",
            version: 1,
            isDeleted: false,
            endDate: endDate
        )
    }

    /// 2026-05-18T12:00:00.000Z — matches the TS suite's NOW fixture.
    private var now: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: "2026-05-18T12:00:00.000Z")!
    }

    // MARK: - Tests

    func test_indefiniteTask_noEndDate_returnsFalse() {
        XCTAssertFalse(TaskExpiry.isTaskExpired(makeTask(), now: now))
    }

    func test_endDateInThePast_returnsTrue() {
        XCTAssertTrue(
            TaskExpiry.isTaskExpired(makeTask(endDate: "2026-05-10T23:59:59.999Z"), now: now)
        )
    }

    func test_endDateInTheFuture_returnsFalse() {
        XCTAssertFalse(
            TaskExpiry.isTaskExpired(makeTask(endDate: "2026-05-25T23:59:59.999Z"), now: now)
        )
    }

    func test_nowExactlyEqualsEndDate_boundaryInclusive_returnsFalse() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let endIso = formatter.string(from: now)
        XCTAssertFalse(TaskExpiry.isTaskExpired(makeTask(endDate: endIso), now: now))
    }

    func test_unparseableEndDate_defensive_returnsFalse() {
        XCTAssertFalse(TaskExpiry.isTaskExpired(makeTask(endDate: "not-a-date"), now: now))
    }

    // MARK: - Local-ISO without timezone (output of toLocalISO)

    func test_localISOWithoutTimezone_pastEndDate_returnsTrue() {
        XCTAssertTrue(
            TaskExpiry.isTaskExpired(makeTask(endDate: "2026-05-10T23:59:59.999"), now: now)
        )
    }

    func test_localISOWithoutTimezone_futureEndDate_returnsFalse() {
        XCTAssertFalse(
            TaskExpiry.isTaskExpired(makeTask(endDate: "2026-05-25T23:59:59.999"), now: now)
        )
    }

    // MARK: - Calendar-only YYYY-MM-DD

    func test_calendarOnly_severalDaysInThePast_returnsTrue() {
        XCTAssertTrue(TaskExpiry.isTaskExpired(makeTask(endDate: "2026-05-10"), now: now))
    }

    func test_calendarOnly_currentLocalDay_returnsFalse() {
        // NOW is mid-day on 2026-05-18 UTC. Local end-of-day for the same
        // calendar date is still in the future everywhere, so the task is
        // NOT yet expired (guards against a UTC-midnight misparse, which
        // would already be in the past east of UTC).
        XCTAssertFalse(TaskExpiry.isTaskExpired(makeTask(endDate: "2026-05-18"), now: now))
    }

    func test_calendarOnly_futureDate_returnsFalse() {
        XCTAssertFalse(TaskExpiry.isTaskExpired(makeTask(endDate: "2026-05-25"), now: now))
    }
}
