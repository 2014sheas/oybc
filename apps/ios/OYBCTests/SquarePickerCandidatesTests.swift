import XCTest
@testable import OYBC

/// Pure tests for `SquarePickerCandidates` (Board Edit redesign slice 3,
/// D13) — lifted from the retired `CellSwapSheet`'s filter.
final class SquarePickerCandidatesTests: XCTestCase {

    private func makeTask(
        _ id: String, type: TaskType = .normal, isDeleted: Bool = false, title: String? = nil
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: "u1", title: title ?? "Task \(id)", type: type,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: isDeleted
        )
    }

    func test_excludesDeletedTasks() {
        let tasks = [makeTask("t1", isDeleted: true), makeTask("t2")]
        let result = SquarePickerCandidates.filter(.init(
            candidateTasks: tasks, currentTaskId: nil, placedTaskIds: [], counterFamilyByTaskId: [:]
        ))
        XCTAssertEqual(result.map(\.id), ["t2"])
    }

    func test_excludesIneligibleTypes() {
        let tasks = [makeTask("t1", type: .achievement), makeTask("t2", type: .counting)]
        let result = SquarePickerCandidates.filter(.init(
            candidateTasks: tasks, currentTaskId: nil, placedTaskIds: [], counterFamilyByTaskId: [:]
        ))
        // Both achievement and counting ARE eligible for a non-center square.
        XCTAssertEqual(Set(result.map(\.id)), ["t1", "t2"])
    }

    func test_replaceMode_excludesTheOutgoingTask() {
        let tasks = [makeTask("t1"), makeTask("t2")]
        let result = SquarePickerCandidates.filter(.init(
            candidateTasks: tasks, currentTaskId: "t1", placedTaskIds: ["t1"], counterFamilyByTaskId: [:]
        ))
        XCTAssertEqual(result.map(\.id), ["t2"])
    }

    func test_excludesTasksAlreadyInTheDraft() {
        // D13 — placedTaskIds is the DRAFT's current occupants, not the live
        // board. A task staged elsewhere in THIS session is still excluded.
        let tasks = [makeTask("t1"), makeTask("t2")]
        let result = SquarePickerCandidates.filter(.init(
            candidateTasks: tasks, currentTaskId: nil, placedTaskIds: ["t2"], counterFamilyByTaskId: [:]
        ))
        XCTAssertEqual(result.map(\.id), ["t1"])
    }

    func test_excludesSharedCounterFamilyMates() {
        let tasks = [makeTask("t1", type: .counting), makeTask("t2", type: .counting)]
        let result = SquarePickerCandidates.filter(.init(
            candidateTasks: tasks, currentTaskId: nil, placedTaskIds: ["t1"],
            counterFamilyByTaskId: ["t1": "fam-a", "t2": "fam-a"]
        ))
        XCTAssertTrue(result.isEmpty, "t2 shares t1's family, and t1 is already placed")
    }

    func test_replaceMode_familyMateOfTheOutgoingTaskIsAllowed() {
        // Swapping "Read 20" -> "Read 50" (same family) legitimately replaces
        // the family's slot.
        let tasks = [makeTask("t1", type: .counting), makeTask("t2", type: .counting)]
        let result = SquarePickerCandidates.filter(.init(
            candidateTasks: tasks, currentTaskId: "t1", placedTaskIds: ["t1"],
            counterFamilyByTaskId: ["t1": "fam-a", "t2": "fam-a"]
        ))
        XCTAssertEqual(result.map(\.id), ["t2"])
    }

    func test_queryFiltersByTitleCaseInsensitive() {
        let tasks = [makeTask("t1", title: "Read a book"), makeTask("t2", title: "Walk the dog")]
        let result = SquarePickerCandidates.filter(.init(
            candidateTasks: tasks, currentTaskId: nil, placedTaskIds: [], counterFamilyByTaskId: [:],
            query: "READ"
        ))
        XCTAssertEqual(result.map(\.id), ["t1"])
    }

    func test_sortedByTitle() {
        let tasks = [makeTask("t1", title: "Zebra"), makeTask("t2", title: "Apple")]
        let result = SquarePickerCandidates.filter(.init(
            candidateTasks: tasks, currentTaskId: nil, placedTaskIds: [], counterFamilyByTaskId: [:]
        ))
        XCTAssertEqual(result.map(\.id), ["t2", "t1"])
    }
}
