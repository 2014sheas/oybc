import XCTest
@testable import OYBC

/// Wizard-preview windowed completion (the "green squares from previous
/// windows" bug): `wizardPreviewIsCompleted` (BoardWizardPersist.swift) must
/// resolve a preview cell's done state against the PROSPECTIVE board's window
/// (`[resolveWizardDates(...).start, ∞)`), never the task's lifetime cache.
/// Mirrors the web pin in `wizardPreviewWindowed.test.ts` — same cases, same
/// expected booleans.
final class WizardPreviewCompletionTests: XCTestCase {

    private let windowStart = "2026-07-01T00:00:00.000Z"
    private let beforeWindow = "2026-06-15T12:00:00.000Z"
    private let inWindow = "2026-07-10T12:00:00.000Z"

    private func makeTask(
        _ id: String,
        type: TaskType = .normal,
        maxCount: Int? = nil,
        operatorType: OperatorType? = nil,
        isCompleted: Bool = false,
        currentCount: Int? = nil,
        sharedCounterId: String? = nil
    ) -> Task {
        Task(
            id: id, userId: "u1", title: id,
            type: type,
            maxCount: maxCount,
            operatorType: operatorType,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted,
            currentCount: currentCount,
            createdAt: beforeWindow, updatedAt: beforeWindow,
            version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId
        )
    }

    private func makeEvent(
        taskId: String,
        kind: TaskEventKind,
        occurredAt: String,
        delta: Int? = nil
    ) -> TaskEvent {
        TaskEvent(
            id: UUID().uuidString, userId: "u1", taskId: taskId,
            kind: kind, delta: delta, occurredAt: occurredAt, boardId: nil,
            createdAt: occurredAt, updatedAt: occurredAt, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
    }

    func testPreviousWindowCompletionPreviewsGrey() {
        let task = makeTask("t1", isCompleted: true)
        let done = wizardPreviewIsCompleted(
            task: task,
            taskById: [task.id: task],
            childrenByCompound: [:],
            eventsByTaskId: [task.id: [makeEvent(taskId: task.id, kind: .completion, occurredAt: beforeWindow)]],
            windowStart: windowStart,
            windowEnd: nil
        )
        XCTAssertFalse(done, "a lifetime-completed task with only pre-window events must preview grey")
    }

    func testInWindowCompletionPreviewsGreen() {
        let task = makeTask("t1", isCompleted: true)
        let done = wizardPreviewIsCompleted(
            task: task,
            taskById: [task.id: task],
            childrenByCompound: [:],
            eventsByTaskId: [task.id: [makeEvent(taskId: task.id, kind: .completion, occurredAt: inWindow)]],
            windowStart: windowStart,
            windowEnd: nil
        )
        XCTAssertTrue(done)
    }

    func testCountingResolvesOnlyInWindowIncrements() {
        let task = makeTask("c1", type: .counting, maxCount: 5, isCompleted: true, currentCount: 5)
        let events = [
            makeEvent(taskId: task.id, kind: .increment, occurredAt: beforeWindow, delta: 5),
            makeEvent(taskId: task.id, kind: .increment, occurredAt: inWindow, delta: 2),
        ]
        let done = wizardPreviewIsCompleted(
            task: task,
            taskById: [task.id: task],
            childrenByCompound: [:],
            eventsByTaskId: [task.id: events],
            windowStart: windowStart,
            windowEnd: nil
        )
        XCTAssertFalse(done, "only the in-window sum (2 of 5) counts toward the goal")
    }

    /// Owner rule 2026-10-01: a hub-linked counter previews from the ROOT's
    /// in-window increments (the prospective board's window), not its latch.
    func testHubLinkedCounterReadsRootEventsInWindowNotLatch() {
        let task = makeTask(
            "d1", type: .counting, maxCount: 10,
            isCompleted: true, currentCount: 10, sharedCounterId: "src-1"
        )
        func preview(_ events: [String: [TaskEvent]]) -> Bool {
            wizardPreviewIsCompleted(
                task: task, taskById: [task.id: task], childrenByCompound: [:],
                eventsByTaskId: events, windowStart: windowStart, windowEnd: nil
            )
        }
        XCTAssertFalse(preview([:]), "the stale latch is not read")
        XCTAssertFalse(preview(["src-1": [makeEvent(taskId: "src-1", kind: .increment, occurredAt: beforeWindow, delta: 10)]]))
        XCTAssertTrue(preview(["src-1": [makeEvent(taskId: "src-1", kind: .increment, occurredAt: inWindow, delta: 10)]]))
    }

    func testCompoundEvaluatesWindowedThroughChildren() {
        let child = makeTask("child-1", isCompleted: true)
        let compound = makeTask("comp-1", type: .compound, operatorType: .and, isCompleted: true)
        let link = CompoundChild(
            id: "cc-1", compoundTaskId: compound.id, childTaskId: child.id,
            childIndex: 0, createdAt: beforeWindow, updatedAt: beforeWindow,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
        let taskById = [compound.id: compound, child.id: child]
        let children = [compound.id: [link]]

        let stale = wizardPreviewIsCompleted(
            task: compound,
            taskById: taskById,
            childrenByCompound: children,
            eventsByTaskId: [child.id: [makeEvent(taskId: child.id, kind: .completion, occurredAt: beforeWindow)]],
            windowStart: windowStart,
            windowEnd: nil
        )
        XCTAssertFalse(stale, "a compound whose child completed in a previous window must preview grey")

        let fresh = wizardPreviewIsCompleted(
            task: compound,
            taskById: taskById,
            childrenByCompound: children,
            eventsByTaskId: [child.id: [makeEvent(taskId: child.id, kind: .completion, occurredAt: inWindow)]],
            windowStart: windowStart,
            windowEnd: nil
        )
        XCTAssertTrue(fresh)
    }

    // MARK: - wizardPreviewCount (owner report 2026-10-04: Board Edit / the
    // wizard's Rearrange grid showed a counter's LIFETIME progress)

    func testPreviewCountSumsOnlyInWindowIncrements_notLifetimeCache() {
        let task = makeTask("c1", type: .counting, maxCount: 50, currentCount: 40)
        let events = [
            makeEvent(taskId: task.id, kind: .increment, occurredAt: beforeWindow, delta: 30),
            makeEvent(taskId: task.id, kind: .increment, occurredAt: inWindow, delta: 12),
        ]
        let count = wizardPreviewCount(
            task: task, eventsByTaskId: [task.id: events],
            windowStart: windowStart, windowEnd: nil
        )
        XCTAssertEqual(count, 12, "only the in-window increment counts; the lifetime cache (40) is never read")
    }

    func testPreviewCountLinkedRowReadsRootEventsInWindow() {
        let root = makeTask("root", type: .counting, maxCount: 100, currentCount: 77)
        let linked = makeTask("linked", type: .counting, maxCount: 20, currentCount: 77, sharedCounterId: root.id)
        let events = [
            makeEvent(taskId: root.id, kind: .increment, occurredAt: beforeWindow, delta: 70),
            makeEvent(taskId: root.id, kind: .increment, occurredAt: inWindow, delta: 7),
        ]
        let count = wizardPreviewCount(
            task: linked, eventsByTaskId: [root.id: events],
            windowStart: windowStart, windowEnd: nil
        )
        XCTAssertEqual(count, 7, "a linked row shows the ROOT's in-window sum, not its propagated lifetime mirror")
    }

    func testPreviewCountNonCountingKeepsCache() {
        let task = makeTask("n1", currentCount: 3)
        XCTAssertEqual(
            wizardPreviewCount(task: task, eventsByTaskId: [:], windowStart: windowStart, windowEnd: nil),
            3
        )
    }
}
