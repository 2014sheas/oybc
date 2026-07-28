import XCTest
@testable import OYBC

/// Unit tests for `deriveCounterDailyTotals` in `Helpers/CounterDailyTotals.swift`.
///
/// Swift port of `packages/shared/tests/algorithms/counterDailyTotals.test.ts`
/// — mirrors every case (case-for-case) so drift between the TS source of
/// truth and the Swift port is caught immediately.
///
/// Note: the TS suite's "throws for a non-integer days value" case has no
/// Swift analog — `days: Int` is compile-time integer-typed, so a fractional
/// value can't be passed at all.
final class CounterDailyTotalsTests: XCTestCase {

    private let source = "source-task-1"
    private let seedSentinel = "1970-01-01T00:00:00.000Z"

    /// "Now" pinned to 2026-07-20 (a Monday), mid-afternoon local time.
    /// Deliberately LOCAL-ISO (no trailing `Z`), matching the TS fixture
    /// convention — `DateFormatting.parseISO` resolves this as device-local
    /// wall-clock time, so day-bucketing is deterministic regardless of the
    /// test runner's timezone.
    private let now = "2026-07-20T15:00:00.000"

    private func ev(
        occurredAt: String,
        delta: Int,
        kind: TaskEventKind = .increment,
        taskId: String? = nil,
        isDeleted: Bool = false
    ) -> TaskEvent {
        TaskEvent(
            id: UUID().uuidString,
            userId: "u1",
            taskId: taskId ?? source,
            kind: kind,
            delta: kind == .increment ? delta : nil,
            occurredAt: occurredAt,
            boardId: nil,
            createdAt: occurredAt,
            updatedAt: occurredAt,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: isDeleted,
            deletedAt: nil
        )
    }

    private func derive(_ events: [TaskEvent], days: Int = 7, seedSentinel: String? = nil) throws -> CounterDailyTotalsResult {
        try deriveCounterDailyTotals(
            events: events,
            sourceTaskId: source,
            now: now,
            days: days,
            seedSentinel: seedSentinel ?? self.seedSentinel
        )
    }

    func test_returnsExactlyDaysZeroFilledEntriesWhenNoEvents() throws {
        let result = try derive([])
        XCTAssertEqual(result.days.count, 7)
        XCTAssertTrue(result.days.allSatisfy { $0.total == 0 })
        XCTAssertEqual(result.todayTotal, 0)
    }

    func test_ordersDaysOldestFirstTodayLastAsYYYYMMDD() throws {
        let result = try derive([], days: 3)
        XCTAssertEqual(result.days.map(\.dateISO), ["2026-07-18", "2026-07-19", "2026-07-20"])
    }

    func test_bucketsMultipleSameDayEventsTogether() throws {
        let events = [
            ev(occurredAt: "2026-07-20T09:00:00.000", delta: 5),
            ev(occurredAt: "2026-07-20T18:30:00.000", delta: 3),
        ]
        let result = try derive(events)
        let today = result.days.last!
        XCTAssertEqual(today.dateISO, "2026-07-20")
        XCTAssertEqual(today.total, 8)
        XCTAssertEqual(result.todayTotal, 8)
    }

    func test_keepsSeparateDayEventsInSeparateBuckets() throws {
        let events = [
            ev(occurredAt: "2026-07-18T09:00:00.000", delta: 4),
            ev(occurredAt: "2026-07-19T09:00:00.000", delta: 6),
        ]
        let result = try derive(events)
        let byDate = Dictionary(uniqueKeysWithValues: result.days.map { ($0.dateISO, $0.total) })
        XCTAssertEqual(byDate["2026-07-18"], 4)
        XCTAssertEqual(byDate["2026-07-19"], 6)
        XCTAssertEqual(byDate["2026-07-20"], 0)
    }

    func test_zeroFillsDaysWithNoActivity() throws {
        let events = [ev(occurredAt: "2026-07-20T09:00:00.000", delta: 2)]
        let result = try derive(events)
        XCTAssertTrue(result.days.dropLast().allSatisfy { $0.total == 0 })
    }

    func test_excludesSeedSentinelEvenWhenItWouldOtherwiseLandInWindow() throws {
        // Use a sentinel value that DOES fall inside the trailing window, to
        // prove exclusion is by exact occurredAt match, not merely "too old
        // to matter".
        let sentinel = "2026-07-20T00:00:01.000"
        let events = [
            ev(occurredAt: sentinel, delta: 999),
            ev(occurredAt: "2026-07-20T09:00:00.000", delta: 2),
        ]
        let result = try derive(events, seedSentinel: sentinel)
        XCTAssertEqual(result.todayTotal, 2)
    }

    func test_excludesRealFarPastSeedSentinelFromBucketing() throws {
        let events = [
            ev(occurredAt: seedSentinel, delta: 1_000),
            ev(occurredAt: "2026-07-20T09:00:00.000", delta: 2),
        ]
        let result = try derive(events)
        XCTAssertEqual(result.days.reduce(0) { $0 + $1.total }, 2)
    }

    func test_sumsNegativeDeltasADecrementEventReducesADayTotal() throws {
        let events = [
            ev(occurredAt: "2026-07-20T09:00:00.000", delta: 10),
            ev(occurredAt: "2026-07-20T10:00:00.000", delta: -4),
        ]
        let result = try derive(events)
        XCTAssertEqual(result.todayTotal, 6)
    }

    func test_excludesEventsOutsideTrailingWindow7DayEdge() throws {
        // 7-day window ending 2026-07-20 starts 2026-07-14. An event on
        // 2026-07-13 (8 days back) must be excluded; one on 2026-07-14
        // (exactly the window's oldest day) must be included.
        let events = [
            ev(occurredAt: "2026-07-13T09:00:00.000", delta: 100),
            ev(occurredAt: "2026-07-14T09:00:00.000", delta: 7),
        ]
        let result = try derive(events)
        XCTAssertEqual(result.days.first?.dateISO, "2026-07-14")
        XCTAssertEqual(result.days.first?.total, 7)
        XCTAssertEqual(result.days.reduce(0) { $0 + $1.total }, 7)
    }

    func test_ignoresEventsForADifferentTask() throws {
        let events = [ev(occurredAt: "2026-07-20T09:00:00.000", delta: 50, taskId: "other-task")]
        let result = try derive(events)
        XCTAssertEqual(result.todayTotal, 0)
    }

    func test_ignoresNonIncrementCompletionEvents() throws {
        let events = [ev(occurredAt: "2026-07-20T09:00:00.000", delta: 50, kind: .completion)]
        let result = try derive(events)
        XCTAssertEqual(result.todayTotal, 0)
    }

    func test_ignoresSoftDeletedEvents() throws {
        let events = [ev(occurredAt: "2026-07-20T09:00:00.000", delta: 50, isDeleted: true)]
        let result = try derive(events)
        XCTAssertEqual(result.todayTotal, 0)
    }

    func test_doesNotSpecialCasePreAmountEventsDelta1() throws {
        let events = [
            ev(occurredAt: "2026-07-20T09:00:00.000", delta: 1),
            ev(occurredAt: "2026-07-20T10:00:00.000", delta: 1),
            ev(occurredAt: "2026-07-20T11:00:00.000", delta: 1),
        ]
        let result = try derive(events)
        XCTAssertEqual(result.todayTotal, 3)
    }

    func test_throwsForNonPositiveDaysValue() {
        XCTAssertThrowsError(try derive([], days: 0))
        XCTAssertThrowsError(try derive([], days: -1))
    }
}
