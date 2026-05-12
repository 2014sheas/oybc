import XCTest
@testable import OYBC

/// Phase 6.3 — iOS mirror of `packages/shared/tests/algorithms/cycleDetection.test.ts`.
/// When that changes, this must change in lockstep.
///
/// After the ACHIEVEMENT-as-TaskType refactor:
///   - The cycle-check candidate is a `Task` (not a `BoardTask`) carrying
///     reference fields, plus a list of `parentBoardIds` (boards placing
///     the candidate). Edges are contributed by `BoardTask` placements
///     whose backing Task is `.achievement`-typed.
///   - Each test seeds an achievement Task with its references and a
///     placement BoardTask connecting that Task to its parent board(s).
final class CycleDetectionTests: XCTestCase {

    // MARK: - Helpers (JSON round-trip — Board has a custom decoder)

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

    /// Build an ACHIEVEMENT-typed Task carrying the given references.
    /// Mutual exclusion is the caller's responsibility — these tests
    /// deliberately set one or the other.
    private func achievementTask(
        _ id: String,
        referencedBoardId: String? = nil,
        referencedTemplateId: String? = nil,
        isDeleted: Bool = false
    ) -> Task {
        return Task(
            id: id,
            userId: "u",
            title: id,
            type: .achievement,
            referencedBoardId: referencedBoardId,
            referencedTemplateId: referencedTemplateId,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: "2026-04-23T00:00:00.000Z",
            updatedAt: "2026-04-23T00:00:00.000Z",
            version: 1,
            isDeleted: isDeleted
        )
    }

    /// Place a Task on a board (pure placement record).
    private func placement(_ boardId: String, _ taskId: String, _ idx: Int = 0) -> BoardTask {
        return BoardTask(
            id: "bt-\(boardId)-\(taskId)-\(idx)",
            boardId: boardId,
            taskId: taskId,
            row: 0,
            col: idx,
            isCenter: false,
            createdAt: "2026-04-23T00:00:00.000Z",
            updatedAt: "2026-04-23T00:00:00.000Z",
            version: 1
        )
    }

    // MARK: - referencedBoardId edges

    func testHasCycle_EmptyParents_TriviallySafe() {
        // No placements yet → no edges contributed, no cycle possible.
        let a = board("a")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: [], referencedBoardId: "a", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: [], allTasks: [], allBoards: [a])
        )
        XCTAssertEqual(result, .ok)
    }

    func testHasCycle_SelfReferenceByBoardId_DegenerateCycle() {
        let a = board("a")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["a"], referencedBoardId: "a", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: [], allTasks: [], allBoards: [a])
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
        // Existing: achievement Task watching A is placed on B.
        let tBA = achievementTask("tBA", referencedBoardId: "a")
        let pBA = placement("b", "tBA")
        // Candidate: a NEW achievement Task watching B, about to be placed on A.
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["a"], referencedBoardId: "b", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: [pBA], allTasks: [tBA], allBoards: [a, b])
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
        // B → C
        let tBC = achievementTask("tBC", referencedBoardId: "c")
        let pBC = placement("b", "tBC")
        // C → A
        let tCA = achievementTask("tCA", referencedBoardId: "a")
        let pCA = placement("c", "tCA")
        // Candidate: A → B closes the loop.
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["a"], referencedBoardId: "b", referencedTemplateId: nil),
            context: CycleCheckContext(
                allBoardTasks: [pBC, pCA],
                allTasks: [tBC, tCA],
                allBoards: [a, b, c]
            )
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
        // Existing: A → C
        let tAC = achievementTask("tAC", referencedBoardId: "c")
        let pAC = placement("a", "tAC")
        // Candidate: A → B (fan-out from A — no return path)
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["a"], referencedBoardId: "b", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: [pAC], allTasks: [tAC], allBoards: [a, b, c])
        )
        XCTAssertEqual(result, .ok)
    }

    func testHasCycle_EmptyGraph_Accepted() {
        let a = board("a")
        let b = board("b")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["a"], referencedBoardId: "b", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: [], allTasks: [], allBoards: [a, b])
        )
        XCTAssertEqual(result, .ok)
    }

    func testHasCycle_UnrelatedCycleInGraph_StillAcceptsCandidate() {
        let a = board("a")
        let b = board("b")
        let c = board("c")
        let d = board("d")
        // Pre-existing B↔C cycle.
        let tBC = achievementTask("tBC", referencedBoardId: "c")
        let pBC = placement("b", "tBC")
        let tCB = achievementTask("tCB", referencedBoardId: "b")
        let pCB = placement("c", "tCB")
        // Candidate A→D unrelated to the cycle.
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["a"], referencedBoardId: "d", referencedTemplateId: nil),
            context: CycleCheckContext(
                allBoardTasks: [pBC, pCB],
                allTasks: [tBC, tCB],
                allBoards: [a, b, c, d]
            )
        )
        XCTAssertEqual(result, .ok)
    }

    func testHasCycle_MultiParentCandidate_Rejected() {
        // Pre-existing: an achievement Task watching A placed on C.
        // Candidate: an achievement Task watching C, placed on BOTH A and B.
        // Adjacency A→C and B→C are added by the multi-parent edge-injection
        // loop. The C→A edge already exists, so start=C → A (in parentSet)
        // closes a cycle through parent A. Exercises the `for parentId in
        // parentBoardIds` branch in CycleDetection.hasCycle.
        let a = board("a")
        let b = board("b")
        let c = board("c")
        let tCA = achievementTask("tCA", referencedBoardId: "a")
        let pCA = placement("c", "tCA")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["a", "b"], referencedBoardId: "c", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: [pCA], allTasks: [tCA], allBoards: [a, b, c])
        )
        if case .cycle = result {
            // pass
        } else {
            XCTFail("expected cycle via multi-parent placement → C → A loop")
        }
    }

    func testHasCycle_NonAchievementTaskPlacement_ContributesNoEdges() {
        // A NORMAL Task placed on B has no reference → no edge contributed.
        // Candidate A→B is therefore safe.
        let a = board("a")
        let b = board("b")
        let normalTask = Task(
            id: "norm",
            userId: "u",
            title: "norm",
            type: .normal,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: "2026-04-23T00:00:00.000Z",
            updatedAt: "2026-04-23T00:00:00.000Z",
            version: 1,
            isDeleted: false
        )
        let pNorm = placement("b", "norm")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["a"], referencedBoardId: "b", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: [pNorm], allTasks: [normalTask], allBoards: [a, b])
        )
        XCTAssertEqual(result, .ok)
    }

    // MARK: - referencedTemplateId edges

    func testHasCycle_TemplateSelfReference_DegenerateCycle() {
        let parent = board("p", spawnedFromTemplateId: "t1")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["p"], referencedBoardId: nil, referencedTemplateId: "t1"),
            context: CycleCheckContext(allBoardTasks: [], allTasks: [], allBoards: [parent])
        )
        if case .cycle(let path) = result {
            XCTAssertEqual(path, ["p", "p"])
        } else {
            XCTFail("expected cycle")
        }
    }

    func testHasCycle_TemplateFanOutClosesCycle_Rejected() {
        // Existing: achievement Task watching parent placed on spawn-1.
        // Candidate: achievement Task watching template t1 placed on parent.
        // Adjacency: parent → spawn-1 (fan-out) → parent → cycle.
        let parent = board("parent")
        let spawn = board("spawn-1", spawnedFromTemplateId: "t1")
        let tBack = achievementTask("tBack", referencedBoardId: "parent")
        let pBack = placement("spawn-1", "tBack")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["parent"], referencedBoardId: nil, referencedTemplateId: "t1"),
            context: CycleCheckContext(allBoardTasks: [pBack], allTasks: [tBack], allBoards: [parent, spawn])
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
            candidate: CycleCheckCandidate(parentBoardIds: ["parent"], referencedBoardId: nil, referencedTemplateId: "t1"),
            context: CycleCheckContext(allBoardTasks: [], allTasks: [], allBoards: [parent])
        )
        XCTAssertEqual(result, .ok)
    }

    func testHasCycle_TwoCycleViaTemplates_Rejected() {
        // A is a spawn of templateU. B is a spawn of templateT.
        // B's achievement Task references templateU (fans out to A).
        // Candidate: A's achievement Task references templateT (fans out to B).
        // Closes A → B → A.
        let a = board("a", spawnedFromTemplateId: "tu")
        let b = board("b", spawnedFromTemplateId: "tt")
        let tB = achievementTask("tB", referencedTemplateId: "tu")
        let pB = placement("b", "tB")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["a"], referencedBoardId: nil, referencedTemplateId: "tt"),
            context: CycleCheckContext(allBoardTasks: [pB], allTasks: [tB], allBoards: [a, b])
        )
        if case .cycle = result {
            // pass
        } else {
            XCTFail("expected cycle via template→spawn→template")
        }
    }

    func testHasCycle_SoftDeletedSpawnDoesNotContributeEdge_Accepted() {
        // Soft-deleted spawn has an achievement Task pointing back at
        // parent, but the deleted board is filtered from adjacency.
        let parent = board("parent")
        let spawn = board("spawn-1", spawnedFromTemplateId: "t1", isDeleted: true)
        let tBack = achievementTask("tBack", referencedBoardId: "parent")
        let pBack = placement("spawn-1", "tBack")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["parent"], referencedBoardId: nil, referencedTemplateId: "t1"),
            context: CycleCheckContext(allBoardTasks: [pBack], allTasks: [tBack], allBoards: [parent, spawn])
        )
        XCTAssertEqual(result, .ok)
    }

    func testHasCycle_SoftDeletedAchievementTask_ContributesNoEdges() {
        // A deleted achievement Task is filtered out of tasksById, so
        // its placement contributes no edge to the graph.
        let a = board("a")
        let b = board("b")
        let tDel = achievementTask("tDel", referencedBoardId: "a", isDeleted: true)
        let pDel = placement("b", "tDel")
        let result = CycleDetection.hasCycle(
            candidate: CycleCheckCandidate(parentBoardIds: ["a"], referencedBoardId: "b", referencedTemplateId: nil),
            context: CycleCheckContext(allBoardTasks: [pDel], allTasks: [tDel], allBoards: [a, b])
        )
        XCTAssertEqual(result, .ok)
    }
}
