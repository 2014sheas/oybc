import XCTest
@testable import OYBC

/// Swift twin of `packages/shared/tests/algorithms/compoundChildEligibility.test.ts`.
/// One refusal per check, each built so every EARLIER check passes (pins the
/// check order), plus the allowed case: a nested compound forming no loop.
/// Strings are asserted as literals so a drift from the web copy fails here.
final class CompoundChildEligibilityTests: XCTestCase {

    private func task(
        _ id: String, type: TaskType = .normal, isDeleted: Bool = false,
        isCounter: Bool = false, maxCount: Int? = nil
    ) -> Task {
        var t = Task(
            id: id, userId: "u1", title: "Task \(id)", type: type,
            totalCompletions: 0, totalInstances: 0, isCompleted: false,
            createdAt: "2026-09-01T12:00:00.000", updatedAt: "2026-09-01T12:00:00.000",
            version: 1, isDeleted: isDeleted
        )
        t.isCounter = isCounter
        t.maxCount = maxCount
        return t
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

    func test_refusesGoalLessCounter() {
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "P", candidate: task("G", type: .counting, isCounter: true),
                allLinks: [], currentChildIds: ["X"]),
            "Counters without a goal can’t be sub-tasks."
        )
    }

    func test_allowsCounterWithGoal() {
        XCTAssertNil(CompoundChildEligibility.linkProblem(
            parentId: "P", candidate: task("G", type: .counting, isCounter: true, maxCount: 10),
            allLinks: [], currentChildIds: ["X"]))
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

    // MARK: - Check order (each candidate trips its own check AND every later
    // one, so swapping any adjacent pair of checks changes the message).

    func test_order_selfWinsOverEverything() {
        let links = chain + [link("R", "R")]  // R is its own ancestor too
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "R", candidate: task("R", type: .achievement, isDeleted: true),
                allLinks: links, currentChildIds: ["R"]),
            "A compound can’t contain itself."
        )
    }

    func test_order_duplicateWinsOverAchievementDeletedLoop() {
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "R", candidate: task("P", type: .achievement, isDeleted: true),
                allLinks: chain, currentChildIds: ["P"]),
            "That task is already a sub-task here."
        )
    }

    func test_order_achievementWinsOverDeletedLoop() {
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "R", candidate: task("P", type: .achievement, isDeleted: true),
                allLinks: chain, currentChildIds: []),
            "Achievements can’t be sub-tasks."
        )
    }

    func test_order_deletedWinsOverGoalLessLoop() {
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "R", candidate: task("P", type: .counting, isDeleted: true, isCounter: true),
                allLinks: chain, currentChildIds: []),
            "That task was deleted."
        )
    }

    func test_order_goalLessWinsOverLoop() {
        XCTAssertEqual(
            CompoundChildEligibility.linkProblem(
                parentId: "R", candidate: task("P", type: .counting, isCounter: true),
                allLinks: chain, currentChildIds: []),
            "Counters without a goal can’t be sub-tasks."
        )
    }
}
