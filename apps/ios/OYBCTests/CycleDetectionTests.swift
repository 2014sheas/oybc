import XCTest
@testable import OYBC

/// Phase 6.3 — iOS mirror of `packages/shared/tests/algorithms/cycleDetection.test.ts`.
/// When that changes, this must change in lockstep.
final class CycleDetectionTests: XCTestCase {

    // MARK: - Helpers (JSON round-trip — Board / BoardTask have custom decoders)

    private func board(
        _ id: String,
        spawnedFromTemplateId: String? = nil,
        isDeleted: Bool = false
    ) -> Board {
        var dict: [String: Any] = [
            "id": id,
            "userId": "u",
            "name": id,
            "status": "active",
            "boardSize": 3,
            "timeframe": "monthly",
            "startDate": "2026-04-01T00:00:00.000Z",
            "endDate": "2026-04-30T23:59:59.000Z",
            "centerSquareType": "none",
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "completedLineIds": "[]",
            "createdAt": "2026-04-23T00:00:00.000Z",
            "updatedAt": "2026-04-23T00:00:00.000Z",
            "version": 1,
            "isDeleted": isDeleted,
        ]
        if let tid = spawnedFromTemplateId { dict["spawnedFromTemplateId"] = tid }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func squareRefBoard(_ boardId: String, _ refBoardId: String, _ idx: Int = 0) -> BoardTask {
        var dict: [String: Any] = [
            "id": "bt-\(boardId)-\(refBoardId)-\(idx)",
            "boardId": boardId,
            "taskId": "task-\(idx)",
            "row": 0,
            "col": idx,
            "isCenter": false,
            "isAchievementSquare": true,
            "referencedBoardId": refBoardId,
            "createdAt": "2026-04-23T00:00:00.000Z",
            "updatedAt": "2026-04-23T00:00:00.000Z",
            "version": 1,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(BoardTask.self, from: data)
    }

    private func squareRefTemplate(_ boardId: String, _ refTemplateId: String, _ idx: Int = 0) -> BoardTask {
        var dict: [String: Any] = [
            "id": "bt-\(boardId)-\(refTemplateId)-\(idx)",
            "boardId": boardId,
            "taskId": "task-\(idx)",
            "row": 0,
            "col": idx,
            "isCenter": false,
            "isAchievementSquare": true,
            "referencedTemplateId": refTemplateId,
            "createdAt": "2026-04-23T00:00:00.000Z",
            "updatedAt": "2026-04-23T00:00:00.000Z",
            "version": 1,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(BoardTask.self, from: data)
    }

    // MARK: - referencedBoardId edges

    func testHasCycle_SelfReferenceByBoardId_DegenerateCycle() {
        let a = board("a")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "a", referencedBoardId: "a", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: [], allBoards: [a])
        )
        if case .cycle(let path) = result {
            XCTAssertEqual(path, ["a", "a"])
        } else {
            XCTFail("expected cycle")
        }
    }

    func testHasCycle_TwoCycleViaBoards_Rejected() {
        let a = board("a")
        let b = board("b")
        let existing = [squareRefBoard("b", "a")]
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "a", referencedBoardId: "b", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: existing, allBoards: [a, b])
        )
        if case .cycle(let path) = result {
            XCTAssertEqual(path.first, "a")
            XCTAssertEqual(path.last, "a")
            XCTAssertTrue(path.contains("b"))
        } else {
            XCTFail("expected cycle")
        }
    }

    func testHasCycle_ThreeCycleViaBoards_Rejected() {
        let a = board("a")
        let b = board("b")
        let c = board("c")
        let existing = [squareRefBoard("b", "c"), squareRefBoard("c", "a")]
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "a", referencedBoardId: "b", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: existing, allBoards: [a, b, c])
        )
        if case .cycle = result {
            // pass
        } else {
            XCTFail("expected cycle")
        }
    }

    func testHasCycle_NoCycle_FanOutAcceptable() {
        let a = board("a")
        let b = board("b")
        let c = board("c")
        let existing = [squareRefBoard("a", "c")]
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "a", referencedBoardId: "b", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: existing, allBoards: [a, b, c])
        )
        XCTAssertEqual(result, .ok)
    }

    func testHasCycle_EmptyGraph_Accepted() {
        let a = board("a")
        let b = board("b")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "a", referencedBoardId: "b", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: [], allBoards: [a, b])
        )
        XCTAssertEqual(result, .ok)
    }

    func testHasCycle_UnrelatedCycleInGraph_StillAcceptsCandidate() {
        let a = board("a")
        let b = board("b")
        let c = board("c")
        let d = board("d")
        // Pre-existing B↔C cycle (e.g., a sync race put it there); the
        // candidate A→D is unrelated to that cycle → must still pass.
        let existing = [squareRefBoard("b", "c"), squareRefBoard("c", "b")]
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "a", referencedBoardId: "d", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: existing, allBoards: [a, b, c, d])
        )
        XCTAssertEqual(result, .ok)
    }

    // MARK: - referencedTemplateId edges

    func testHasCycle_TemplateSelfReference_DegenerateCycle() {
        let parent = board("p", spawnedFromTemplateId: "t1")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "p", referencedBoardId: nil, referencedTemplateId: "t1"),
            context: CycleCheckContext(allBoardTasks: [], allBoards: [parent])
        )
        if case .cycle(let path) = result {
            XCTAssertEqual(path, ["p", "p"])
        } else {
            XCTFail("expected cycle")
        }
    }

    func testHasCycle_TemplateFanOutClosesCycle_Rejected() {
        // Existing edge: spawn-1 (a spawn of t1) has a square referencing parent.
        // Candidate: parent's square would reference t1, fanning out to spawn-1
        // → cycle parent → spawn-1 → parent.
        let parent = board("parent")
        let spawn = board("spawn-1", spawnedFromTemplateId: "t1")
        let existing = [squareRefBoard("spawn-1", "parent")]
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "parent", referencedBoardId: nil, referencedTemplateId: "t1"),
            context: CycleCheckContext(allBoardTasks: existing, allBoards: [parent, spawn])
        )
        if case .cycle = result {
            // pass
        } else {
            XCTFail("expected cycle via template fan-out")
        }
    }

    func testHasCycle_TemplateWithZeroSpawnsYet_Accepted() {
        let parent = board("parent")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "parent", referencedBoardId: nil, referencedTemplateId: "t1"),
            context: CycleCheckContext(allBoardTasks: [], allBoards: [parent])
        )
        XCTAssertEqual(result, .ok)
    }

    func testHasCycle_TwoCycleViaTemplates_Rejected() {
        // A is a spawn of templateU. B is a spawn of templateT.
        // B's square references templateU (which fans out to A).
        // Candidate: A's square references templateT (which fans out to B).
        // Closes A → B → A.
        let a = board("a", spawnedFromTemplateId: "tu")
        let b = board("b", spawnedFromTemplateId: "tt")
        let existing = [squareRefTemplate("b", "tu")]
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "a", referencedBoardId: nil, referencedTemplateId: "tt"),
            context: CycleCheckContext(allBoardTasks: existing, allBoards: [a, b])
        )
        if case .cycle = result {
            // pass
        } else {
            XCTFail("expected cycle via template→spawn→template")
        }
    }

    func testHasCycle_SoftDeletedSpawnDoesNotContributeEdge_Accepted() {
        // Soft-deleted spawn has a square pointing back at parent, but
        // it's filtered out — no contribution to the adjacency.
        let parent = board("parent")
        let spawn = board("spawn-1", spawnedFromTemplateId: "t1", isDeleted: true)
        let existing = [squareRefBoard("spawn-1", "parent")]
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(boardId: "parent", referencedBoardId: nil, referencedTemplateId: "t1"),
            context: CycleCheckContext(allBoardTasks: existing, allBoards: [parent, spawn])
        )
        XCTAssertEqual(result, .ok)
    }
}
