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
            windowStart: windowStart
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
            windowStart: windowStart
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
            windowStart: windowStart
        )
        XCTAssertFalse(done, "only the in-window sum (2 of 5) counts toward the goal")
    }

    func testDerivedCounterKeepsLifetimeCarveOut() {
        let task = makeTask(
            "d1", type: .counting, maxCount: 10,
            isCompleted: true, currentCount: 10, sharedCounterId: "src-1"
        )
        let done = wizardPreviewIsCompleted(
            task: task,
            taskById: [task.id: task],
            childrenByCompound: [:],
            eventsByTaskId: [:],
            windowStart: windowStart
        )
        XCTAssertTrue(done, "derived counters read their propagation-stamped lifetime cache")
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
            windowStart: windowStart
        )
        XCTAssertFalse(stale, "a compound whose child completed in a previous window must preview grey")

        let fresh = wizardPreviewIsCompleted(
            task: compound,
            taskById: taskById,
            childrenByCompound: children,
            eventsByTaskId: [child.id: [makeEvent(taskId: child.id, kind: .completion, occurredAt: inWindow)]],
            windowStart: windowStart
        )
        XCTAssertTrue(fresh)
    }
}
