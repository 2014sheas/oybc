import XCTest
@testable import OYBC

/// Swift twin of `packages/shared/tests/algorithms/compoundChildEligibility.test.ts`.
/// One refusal per check, each built so every EARLIER check passes (pins the
/// check order), plus the allowed case: a nested compound forming no loop.
/// Strings are asserted as literals so a drift from the web copy fails here.
final class CompoundChildEligibilityTests: XCTestCase {

    private func task(_ id: String, type: TaskType = .normal, isDeleted: Bool = false) -> Task {
        Task(
            id: id, userId: "u1", title: "Task \(id)", type: type,
            totalCompletions: 0, totalInstances: 0, isCompleted: false,
            createdAt: "2026-09-01T12:00:00.000", updatedAt: "2026-09-01T12:00:00.000",
            version: 1, isDeleted: isDeleted
        )
    }

    private func link(_ parent: String, _ child: String, isDeleted: Bool = false) -> CompoundChild {
        CompoundChild(
            id: "\(parent)->\(child)", compoundTaskId: parent, childTaskId: child, childIndex: 0,
            createdAt: "2026-09-01T12:00:00.000", updatedAt: "2026-09-01T12:00:00.000",
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    /// P contains Q contains R.
    private var chain: [CompoundChild] { [link("P", "Q"), link("Q", "R")] }

    func test_refusesSelf() {
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "P", candidate: task("P", type: .compound), allLinks: chain, currentChildIds: []),
            "A compound can’t contain itself."
        )
    }

    func test_refusesDuplicate() {
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "P", candidate: task("X"), allLinks: [], currentChildIds: ["X"]),
            "That task is already a sub-task here."
        )
    }

    func test_refusesAchievement() {
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "P", candidate: task("A", type: .achievement), allLinks: [], currentChildIds: ["X"]),
            "Achievements can’t be sub-tasks."
        )
    }

    func test_refusesDeleted() {
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "P", candidate: task("D", isDeleted: true), allLinks: [], currentChildIds: ["X"]),
            "That task was deleted."
        )
    }

    /// P→Q→R: linking P under R would close a loop.
    func test_refusesLoop() {
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "R", candidate: task("P", type: .compound), allLinks: chain, currentChildIds: []),
            "That would create a loop — it already contains this compound."
        )
    }

    func test_softDeletedLinksDoNotCountTowardALoop() {
        XCTAssertNil(CompoundChildEligibility.linkProblem(
            parentId: "R", candidate: task("P", type: .compound),
            allLinks: [link("P", "Q"), link("Q", "R", isDeleted: true)], currentChildIds: []))
    }

    func test_allowsNestedCompoundWithoutLoop() {
        XCTAssertNil(CompoundChildEligibility.linkProblem(
            parentId: "Z", candidate: task("Q", type: .compound), allLinks: chain, currentChildIds: ["X"]))
    }
}
