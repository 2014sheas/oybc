import XCTest
@testable import OYBC

/// Unit tests for `selectLastIncrementEntry` in `Helpers/LastCounterLogEntry.swift`.
///
/// Swift port of `packages/shared/tests/algorithms/lastCounterLogEntry.test.ts`
/// — mirrors every case (case-for-case) so drift between the TS source of
/// truth and the Swift port is caught immediately.
final class LastCounterLogEntryTests: XCTestCase {

    private let source = "source-task-1"

    private func ev(
        id: String,
        taskId: String? = nil,
        occurredAt: String = "2026-07-20T09:00:00.000",
        createdAt: String? = nil,
        kind: TaskEventKind = .increment,
        delta: Int? = 1,
        isDeleted: Bool = false
    ) -> TaskEvent {
        TaskEvent(
            id: id,
            userId: "u1",
            taskId: taskId ?? source,
            kind: kind,
            delta: kind == .increment ? delta : nil,
            occurredAt: occurredAt,
            boardId: nil,
            createdAt: createdAt ?? occurredAt,
            updatedAt: createdAt ?? occurredAt,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: isDeleted,
            deletedAt: nil
        )
    }

    func test_returnsNilWhenNoEvents() {
        XCTAssertNil(selectLastIncrementEntry(events: [], sourceTaskId: source))
    }

    func test_returnsNilWhenOnlyEventIsSeedSentinel() {
        let events = [ev(id: "seed", occurredAt: TaskEvents.seedEventOccurredAt)]
        XCTAssertNil(selectLastIncrementEntry(events: events, sourceTaskId: source))
    }

    func test_picksSingleQualifyingEvent() {
        let events = [ev(id: "e1")]
        XCTAssertEqual(selectLastIncrementEntry(events: events, sourceTaskId: source)?.id, "e1")
    }

    func test_picksEventWithMaxOccurredAt() {
        let events = [
            ev(id: "older", occurredAt: "2026-07-18T09:00:00.000"),
            ev(id: "newer", occurredAt: "2026-07-20T09:00:00.000"),
            ev(id: "middle", occurredAt: "2026-07-19T09:00:00.000"),
        ]
        XCTAssertEqual(selectLastIncrementEntry(events: events, sourceTaskId: source)?.id, "newer")
    }

    func test_tieBreaksEqualOccurredAtByMaxCreatedAt() {
        let events = [
            ev(id: "first-written", occurredAt: "2026-07-20T09:00:00.000", createdAt: "2026-07-20T09:00:00.000"),
            ev(id: "second-written", occurredAt: "2026-07-20T09:00:00.000", createdAt: "2026-07-20T09:00:05.000"),
        ]
        XCTAssertEqual(selectLastIncrementEntry(events: events, sourceTaskId: source)?.id, "second-written")
    }

    func test_skipsSoftDeletedEvents() {
        let events = [
            ev(id: "deleted", occurredAt: "2026-07-20T12:00:00.000", isDeleted: true),
            ev(id: "live", occurredAt: "2026-07-19T09:00:00.000"),
        ]
        XCTAssertEqual(selectLastIncrementEntry(events: events, sourceTaskId: source)?.id, "live")
    }

    func test_skipsSeedSentinelEvenWhenMostRecentByOccurredAtValue() {
        let events = [
            ev(id: "seed", occurredAt: TaskEvents.seedEventOccurredAt),
            ev(id: "real", occurredAt: "2026-07-10T09:00:00.000"),
        ]
        XCTAssertEqual(selectLastIncrementEntry(events: events, sourceTaskId: source)?.id, "real")
    }

    func test_skipsCompletionKindEvents() {
        let events = [ev(id: "completion", kind: .completion, delta: nil)]
        XCTAssertNil(selectLastIncrementEntry(events: events, sourceTaskId: source))
    }

    func test_skipsEventsForADifferentTask() {
        let events = [ev(id: "other", taskId: "other-task")]
        XCTAssertNil(selectLastIncrementEntry(events: events, sourceTaskId: source))
    }

    func test_ignoresEventsFromOtherTasksEvenWhenInterleavedWithSourceTask() {
        let events = [
            ev(id: "other-newer", taskId: "other-task", occurredAt: "2026-07-21T09:00:00.000"),
            ev(id: "source-entry", occurredAt: "2026-07-19T09:00:00.000"),
        ]
        XCTAssertEqual(selectLastIncrementEntry(events: events, sourceTaskId: source)?.id, "source-entry")
    }
}
