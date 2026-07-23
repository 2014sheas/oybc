import XCTest
@testable import OYBC

/// Unit tests for `DerivationPass` — parity with
/// `packages/shared/tests/algorithms/derivationPass.test.ts`.
///
/// Three pure functions are tested:
///   - `findTransitiveParentCompounds`
///   - `findAffectedBoardIds`
///   - `computeBoardStatsUpdate`
final class DerivationPassTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal Task with sensible defaults; caller overrides only what matters.
    private func task(
        _ id: String,
        type: TaskType = .normal,
        isCompleted: Bool = false,
        isDeleted: Bool = false,
        operatorType: OperatorType? = nil,
        threshold: Int? = nil
    ) -> Task {
        Task(
            id: id,
            userId: "u",
            title: id,
            type: type,
            operatorType: operatorType,
            threshold: threshold,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: isCompleted,
            createdAt: "2026-04-23T00:00:00.000Z",
            updatedAt: "2026-04-23T00:00:00.000Z",
            version: 1,
            isDeleted: isDeleted
        )
    }

    /// Build a compound Task with the given operator.
    private func compoundTask(
        _ id: String,
        operator op: OperatorType,
        threshold: Int? = nil
    ) -> Task {
        task(id, type: .compound, operatorType: op, threshold: threshold)
    }

    /// Build a CompoundChild link.
    private func child(
        _ parent: String,
        _ childId: String,
        _ idx: Int,
        isDeleted: Bool = false
    ) -> CompoundChild {
        CompoundChild(
            id: "\(parent)-\(childId)-\(idx)",
            compoundTaskId: parent,
            childTaskId: childId,
            childIndex: idx,
            createdAt: "2026-04-23T00:00:00.000Z",
            updatedAt: "2026-04-23T00:00:00.000Z",
            version: 1,
            isDeleted: isDeleted
        )
    }

    /// Build a BoardTask (pure placement record post-Phase-6.3 refactor).
    private func boardTask(
        _ boardId: String,
        _ taskId: String,
        _ row: Int,
        _ col: Int
    ) -> BoardTask {
        return BoardTask(
            id: "\(boardId)-\(taskId)",
            boardId: boardId,
            taskId: taskId,
            row: row,
            col: col,
            isCenter: false,
            createdAt: "2026-04-23T00:00:00.000Z",
            updatedAt: "2026-04-23T00:00:00.000Z",
            version: 1
        )
    }

    /// Build an ACHIEVEMENT-typed Task carrying the given references.
    /// Phase 6.3: achievement-task semantics live on Task, not BoardTask.
    private func achievementTask(
        _ id: String,
        referencedBoardId: String? = nil,
        referencedTemplateId: String? = nil,
        achievementTrigger: AchievementTrigger? = nil,
        requiredCount: Int? = nil
    ) -> Task {
        return Task(
            id: id,
            userId: "u",
            title: id,
            type: .achievement,
            referencedBoardId: referencedBoardId,
            referencedTemplateId: referencedTemplateId,
            achievementTrigger: achievementTrigger,
            requiredCount: requiredCount,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: "2026-04-23T00:00:00.000Z",
            updatedAt: "2026-04-23T00:00:00.000Z",
            version: 1,
            isDeleted: false
        )
    }

    /// Build a Board using JSON round-trip (Board has no memberwise init due to
    /// its custom Codable decoder).
    private func board(
        _ id: String,
        boardSize: Int = 3,
        centerSquareType: CenterSquareType = .none,
        completedLineIds: [String]? = [],
        status: String = "active",
        startDate: String = "2026-04-01T00:00:00.000Z",
        endDate: String = "2026-04-30T23:59:59.000Z",
        spawnedFromTemplateId: String? = nil,
        isDeleted: Bool = false
    ) -> Board {
        // completedLineIds is stored as a JSON-encoded string in the DB/codable layer
        var dict: [String: Any] = [
            "id": id,
            "userId": "u",
            "name": id,
            "status": status,
            "boardSize": boardSize,
            "timeframe": "monthly",
            "startDate": startDate,
            "endDate": endDate,
            "centerSquareType": centerSquareType.rawValue,
            "isRandomized": false,
            "totalTasks": boardSize * boardSize,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-04-23T00:00:00.000Z",
            "updatedAt": "2026-04-23T00:00:00.000Z",
            "version": 1,
            "isDeleted": isDeleted,
        ]
        if let ids = completedLineIds {
            // completedLineIds is stored/decoded as a JSON string inside the row
            let jsonData = try! JSONEncoder().encode(ids)
            dict["completedLineIds"] = String(data: jsonData, encoding: .utf8)!
        }
        if let tid = spawnedFromTemplateId { dict["spawnedFromTemplateId"] = tid }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - findTransitiveParentCompounds: empty

    func testFindTransitiveParentCompounds_ReturnsEmptyWhenNoParent() {
        let children = [child("compA", "otherTask", 0)]
        let result = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: "changedTask",
            children: children
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - findTransitiveParentCompounds: single parent

    func testFindTransitiveParentCompounds_ReturnsSingleParent() {
        let children = [
            child("compA", "changedTask", 0),
            child("compA", "otherTask", 1),
        ]
        let result = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: "changedTask",
            children: children
        )
        XCTAssertEqual(result, ["compA"])
    }

    // MARK: - findTransitiveParentCompounds: grandparent

    func testFindTransitiveParentCompounds_ReturnsParentAndGrandparent() {
        // compB directly contains changedTask; compA contains compB
        let children = [
            child("compB", "changedTask", 0),
            child("compA", "compB", 0),
        ]
        let result = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: "changedTask",
            children: children
        )
        XCTAssertTrue(result.contains("compB"))
        XCTAssertTrue(result.contains("compA"))
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - findTransitiveParentCompounds: soft-deleted filter

    func testFindTransitiveParentCompounds_FiltersSoftDeletedLinks() {
        // compA's link is soft-deleted; compB's link is active
        let children = [
            child("compA", "changedTask", 0, isDeleted: true),
            child("compB", "changedTask", 0),
        ]
        let result = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: "changedTask",
            children: children
        )
        XCTAssertEqual(result, ["compB"])
        XCTAssertFalse(result.contains("compA"))
    }

    // MARK: - findTransitiveParentCompounds: cycle-safe

    func testFindTransitiveParentCompounds_CycleSafe() {
        // changedTask → compA → compB → compA (cycle)
        let children = [
            child("compA", "changedTask", 0),
            child("compB", "compA", 0),
            child("compA", "compB", 1), // cycle: compA also contains compB
        ]
        let result = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: "changedTask",
            children: children
        )
        // Should terminate; both compA and compB should be included
        XCTAssertTrue(result.contains("compA"))
        XCTAssertTrue(result.contains("compB"))
    }

    // MARK: - findAffectedBoardIds: direct placement

    func testFindAffectedBoardIds_ReturnsBoardWithChangedTask() {
        let bts = [boardTask("boardA", "changedTask", 0, 0)]
        let result = DerivationPass.findAffectedBoardIds(
            changedTaskId: "changedTask",
            parentCompounds: [],
            boardTasks: bts
        )
        XCTAssertEqual(result, ["boardA"])
    }

    // MARK: - findAffectedBoardIds: parent-compound placement

    func testFindAffectedBoardIds_ReturnsBoardWithParentCompound() {
        let bts = [boardTask("boardA", "compA", 0, 0)]
        let result = DerivationPass.findAffectedBoardIds(
            changedTaskId: "changedTask",
            parentCompounds: ["compA"],
            boardTasks: bts
        )
        XCTAssertEqual(result, ["boardA"])
    }

    // MARK: - findAffectedBoardIds: union

    func testFindAffectedBoardIds_ReturnsUnionOfBoards() {
        let bts = [
            boardTask("boardA", "changedTask", 0, 0),
            boardTask("boardB", "compA", 1, 1),
        ]
        let result = DerivationPass.findAffectedBoardIds(
            changedTaskId: "changedTask",
            parentCompounds: ["compA"],
            boardTasks: bts
        )
        XCTAssertEqual(result, ["boardA", "boardB"])
    }

    // MARK: - findAffectedBoardIds: empty

    func testFindAffectedBoardIds_ReturnsEmptyWhenNoBoards() {
        let bts = [boardTask("boardA", "unrelatedTask", 0, 0)]
        let result = DerivationPass.findAffectedBoardIds(
            changedTaskId: "changedTask",
            parentCompounds: ["compA"],
            boardTasks: bts
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - findAffectedBoardIds: dedup

    func testFindAffectedBoardIds_DeduplicatesSameBoard() {
        // Same board places both changedTask and parent compound
        let bts = [
            boardTask("boardA", "changedTask", 0, 0),
            boardTask("boardA", "compA", 1, 1),
        ]
        let result = DerivationPass.findAffectedBoardIds(
            changedTaskId: "changedTask",
            parentCompounds: ["compA"],
            boardTasks: bts
        )
        XCTAssertEqual(result, ["boardA"])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - computeBoardStatsUpdate: primitive grid

    func testComputeBoardStats_PrimitiveTaskCompletionCountedCorrectly() {
        let b = board("b1", boardSize: 3, centerSquareType: .none)
        let tDone = task("t1", isCompleted: true)
        let tPending = task("t2", isCompleted: false)
        let bts = [boardTask("b1", "t1", 0, 0), boardTask("b1", "t2", 0, 1)]
        let taskById = ["t1": tDone, "t2": tPending]

        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: bts,
            childrenByCompound: [:],
            taskById: taskById,
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
        // row_0 not fully complete (t2 not done), no bingos
        XCTAssertEqual(result.linesCompleted, 0)
        XCTAssertEqual(result.completedLineIds, [])
    }

    // MARK: - computeBoardStatsUpdate: compound evaluated via evaluator (complete)

    func testComputeBoardStats_CompoundAllChildrenCompleteCounts() {
        let b = board("b1", boardSize: 3, centerSquareType: .none)
        let comp = compoundTask("comp", operator: .and)
        let child1 = task("c1", isCompleted: true)
        let child2 = task("c2", isCompleted: true)
        let bts = [boardTask("b1", "comp", 1, 1)]
        let taskById = ["comp": comp, "c1": child1, "c2": child2]
        let childrenByCompound = ["comp": [child("comp", "c1", 0), child("comp", "c2", 1)]]

        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: bts,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }

    // MARK: - computeBoardStatsUpdate: compound with one incomplete child

    func testComputeBoardStats_CompoundOneChildIncompleteNotCounted() {
        let b = board("b1", boardSize: 3, centerSquareType: .none)
        let comp = compoundTask("comp", operator: .and)
        let child1 = task("c1", isCompleted: true)
        let child2 = task("c2", isCompleted: false)
        let bts = [boardTask("b1", "comp", 1, 1)]
        let taskById = ["comp": comp, "c1": child1, "c2": child2]
        let childrenByCompound = ["comp": [child("comp", "c1", 0), child("comp", "c2", 1)]]

        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: bts,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    // MARK: - computeBoardStatsUpdate: linesCompleted matches BingoDetection

    func testComputeBoardStats_LinesCompletedMatchesBingoDetection() {
        // 3x3 board with row 0 fully complete
        let b = board("b1", boardSize: 3, centerSquareType: .none)
        let t0 = task("t0", isCompleted: true)
        let t1 = task("t1", isCompleted: true)
        let t2 = task("t2", isCompleted: true)
        let bts = [
            boardTask("b1", "t0", 0, 0),
            boardTask("b1", "t1", 0, 1),
            boardTask("b1", "t2", 0, 2),
        ]
        let taskById = ["t0": t0, "t1": t1, "t2": t2]

        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: bts,
            childrenByCompound: [:],
            taskById: taskById,
            windowContext: nil
        )
        XCTAssertEqual(result.linesCompleted, 1)
        XCTAssertTrue(result.completedLineIds.contains("row_0"))
    }

    // MARK: - computeBoardStatsUpdate: new bingo diff

    func testComputeBoardStats_NewBingosDiffedCorrectly() {
        // pre-state: no bingos; post-state: row_0 completed
        let b = board("b1", boardSize: 3, centerSquareType: .none, completedLineIds: [])
        let t0 = task("t0", isCompleted: true)
        let t1 = task("t1", isCompleted: true)
        let t2 = task("t2", isCompleted: true)
        let bts = [
            boardTask("b1", "t0", 0, 0),
            boardTask("b1", "t1", 0, 1),
            boardTask("b1", "t2", 0, 2),
        ]
        let taskById = ["t0": t0, "t1": t1, "t2": t2]

        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: bts,
            childrenByCompound: [:],
            taskById: taskById,
            windowContext: nil
        )
        XCTAssertTrue(result.newBingos.contains("row_0"))
        XCTAssertEqual(result.lostBingos, [])
    }

    // MARK: - computeBoardStatsUpdate: lost bingo diff

    func testComputeBoardStats_LostBingosDiffedCorrectly() {
        // pre-state: row_0 was complete; post-state: no tasks done → row_0 lost
        let b = board("b1", boardSize: 3, centerSquareType: .none, completedLineIds: ["row_0"])
        let t0 = task("t0", isCompleted: false)
        let t1 = task("t1", isCompleted: false)
        let t2 = task("t2", isCompleted: false)
        let bts = [
            boardTask("b1", "t0", 0, 0),
            boardTask("b1", "t1", 0, 1),
            boardTask("b1", "t2", 0, 2),
        ]
        let taskById = ["t0": t0, "t1": t1, "t2": t2]

        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: bts,
            childrenByCompound: [:],
            taskById: taskById,
            windowContext: nil
        )
        XCTAssertTrue(result.lostBingos.contains("row_0"))
        XCTAssertEqual(result.newBingos, [])
    }

    // MARK: - computeBoardStatsUpdate: center auto-fill FREE

    func testComputeBoardStats_CenterAutoFillFreeBoard() {
        // 3x3 FREE board with no task at (1,1) — center treated as completed
        let b = board("b1", boardSize: 3, centerSquareType: .free)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: [],
            childrenByCompound: [:],
            taskById: [:],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }

    // MARK: - computeBoardStatsUpdate: center auto-fill CUSTOM_FREE

    func testComputeBoardStats_CenterAutoFillCustomFreeBoard() {
        let b = board("b1", boardSize: 3, centerSquareType: .customFree)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: [],
            childrenByCompound: [:],
            taskById: [:],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }

    // MARK: - computeBoardStatsUpdate: no auto-fill on CHOSEN

    func testComputeBoardStats_NoAutoFillForChosenCenter() {
        let b = board("b1", boardSize: 3, centerSquareType: .chosen)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: [],
            childrenByCompound: [:],
            taskById: [:],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    // MARK: - computeBoardStatsUpdate: no auto-fill on NONE

    func testComputeBoardStats_NoAutoFillForNoneCenter() {
        let b = board("b1", boardSize: 3, centerSquareType: .none)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: [],
            childrenByCompound: [:],
            taskById: [:],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    // MARK: - computeBoardStatsUpdate: center auto-fill + bingo detection interaction

    func testComputeBoardStats_CenterAutoFillTriggersExpectedBingos() {
        // 3x3 FREE center; col 1 and main diagonal completed via auto-fill + placed tasks
        let b = board("b1", boardSize: 3, centerSquareType: .free)
        let t01 = task("t01", isCompleted: true)  // (0,1)
        let t21 = task("t21", isCompleted: true)  // (2,1)
        let t00 = task("t00", isCompleted: true)  // (0,0)
        let t22 = task("t22", isCompleted: true)  // (2,2)
        let bts = [
            boardTask("b1", "t01", 0, 1),
            boardTask("b1", "t21", 2, 1),
            boardTask("b1", "t00", 0, 0),
            boardTask("b1", "t22", 2, 2),
        ]
        let taskById = ["t01": t01, "t21": t21, "t00": t00, "t22": t22]
        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: bts,
            childrenByCompound: [:],
            taskById: taskById,
            windowContext: nil
        )
        // auto-filled center counts + 4 explicit tasks
        XCTAssertEqual(result.completedTasks, 5)
        XCTAssertTrue(result.completedLineIds.contains("col_1"))
        XCTAssertTrue(result.completedLineIds.contains("diag_main"))
    }

    // MARK: - computeBoardStatsUpdate: soft-deleted Task ignored

    func testComputeBoardStats_SoftDeletedTaskIgnored() {
        let b = board("b1", boardSize: 3, centerSquareType: .none)
        let deletedTask = task("t1", isCompleted: true, isDeleted: true)
        let bts = [boardTask("b1", "t1", 0, 0)]
        let taskById = ["t1": deletedTask]

        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: bts,
            childrenByCompound: [:],
            taskById: taskById,
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    // MARK: - computeBoardStatsUpdate: out-of-bounds row/col

    func testComputeBoardStats_OutOfBoundsRowColSkippedDefensively() {
        let b = board("myBoard", boardSize: 3, centerSquareType: .none)
        let t = task("t1", isCompleted: true)
        let stale = boardTask("myBoard", "t1", 99, 0) // row 99 is out of bounds for a 3x3 board
        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: [stale],
            childrenByCompound: [:],
            taskById: ["t1": t],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
        XCTAssertEqual(result.completedLineIds, [])
    }

    // MARK: - computeBoardStatsUpdate: board.completedLineIds nil → no crash

    func testComputeBoardStats_NilCompletedLineIdsDoesNotCrash() {
        let b = board("myBoard", boardSize: 3, centerSquareType: .none, completedLineIds: nil)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: [],
            childrenByCompound: [:],
            taskById: [:],
            windowContext: nil
        )
        XCTAssertEqual(result.newBingos, [])
        XCTAssertEqual(result.lostBingos, [])
    }

    // MARK: - computeBoardStatsUpdate: boardId in result

    func testComputeBoardStats_BoardIdPassedThrough() {
        let b = board("myBoard", boardSize: 3, centerSquareType: .none)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: [],
            childrenByCompound: [:],
            taskById: [:],
            windowContext: nil
        )
        XCTAssertEqual(result.boardId, "myBoard")
    }

    // MARK: - Phase 6.3: ACHIEVEMENT Task completion (refactored)
    //
    // Achievement-task semantics live on Task (`type == .achievement` +
    // reference fields). BoardTask is a pure placement record — the same
    // achievement Task on multiple boards is just multiple placement rows
    // evaluated against the same Task definition. Aggregate mode is gone
    // (no `achievementType` / `achievementCount` / `achievementProgress`).

    func testComputeBoardStats_AchievementTask_NoReference_CellIncomplete() {
        let b = board("b1", boardSize: 3, centerSquareType: .none)
        // Achievement-typed Task lacking BOTH refs (should be rejected at
        // write time; derivation degrades safely to incomplete).
        let ach = achievementTask("ach1")
        let bt = boardTask("b1", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    func testComputeBoardStats_AchievementTask_IgnoresOwnIsCompleted() {
        // Even if a stale write set isCompleted=true on the achievement
        // Task row, derivation cares about the *reference*, not the field.
        let b = board("b1", boardSize: 3, centerSquareType: .none)
        var ach = achievementTask("ach1")
        ach.isCompleted = true
        let bt = boardTask("b1", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: b,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    // MARK: - Phase 6.3: specific-board mode

    func testComputeBoardStats_ReferencedBoard_Completed_CellCompletes() {
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let ref = board("ref", status: "completed")
        let ach = achievementTask("ach1", referencedBoardId: "ref")
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, ref],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }

    func testComputeBoardStats_ReferencedBoard_Active_CellIncomplete() {
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let ref = board("ref", status: "active")
        let ach = achievementTask("ach1", referencedBoardId: "ref")
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, ref],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    func testComputeBoardStats_ReferencedBoard_SoftDeleted_CellIncomplete() {
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let ref = board("ref", status: "completed", isDeleted: true)
        let ach = achievementTask("ach1", referencedBoardId: "ref")
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, ref],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    func testComputeBoardStats_ReferencedBoard_Missing_CellIncomplete() {
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let ach = achievementTask("ach1", referencedBoardId: "missing")
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    // MARK: - Phase 6.3: recurring-template mode

    func testComputeBoardStats_TemplateAllInWindowCompleted_CellCompletes() {
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let s1 = board("s1", status: "completed", startDate: "2026-04-08T00:00:00.000Z", spawnedFromTemplateId: "t1")
        let s2 = board("s2", status: "completed", startDate: "2026-04-15T00:00:00.000Z", spawnedFromTemplateId: "t1")
        let ach = achievementTask("ach1", referencedTemplateId: "t1", requiredCount: 2)
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, s1, s2],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }

    func testComputeBoardStats_TemplateOneInWindowActive_CellIncomplete() {
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let s1 = board("s1", status: "completed", startDate: "2026-04-08T00:00:00.000Z", spawnedFromTemplateId: "t1")
        let s2 = board("s2", status: "active", startDate: "2026-04-15T00:00:00.000Z", spawnedFromTemplateId: "t1")
        // requiredCount=2 means both spawns must meet trigger; only 1 does.
        let ach = achievementTask("ach1", referencedTemplateId: "t1", requiredCount: 2)
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, s1, s2],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    func testComputeBoardStats_TemplateEmptyWindow_CellIncomplete() {
        // Empty window ⇒ NOT vacuously complete (locked rule).
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let ach = achievementTask("ach1", referencedTemplateId: "t1", requiredCount: 1)
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    func testComputeBoardStats_TemplateOutOfWindow_CellIncomplete() {
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let s1 = board("s1", status: "completed", startDate: "2026-03-15T00:00:00.000Z", spawnedFromTemplateId: "t1")
        let ach = achievementTask("ach1", referencedTemplateId: "t1", requiredCount: 1)
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, s1],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    func testComputeBoardStats_TemplatePartialDelete_CellCompletesIfRemainingAllCompleted() {
        // 4 spawns, 3 COMPLETED + 1 pending soft-deleted → cell completes.
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let s1 = board("s1", status: "completed", startDate: "2026-04-08T00:00:00.000Z", spawnedFromTemplateId: "t1")
        let s2 = board("s2", status: "completed", startDate: "2026-04-15T00:00:00.000Z", spawnedFromTemplateId: "t1")
        let s3 = board("s3", status: "completed", startDate: "2026-04-22T00:00:00.000Z", spawnedFromTemplateId: "t1")
        let s4 = board("s4", status: "active", startDate: "2026-04-29T00:00:00.000Z", spawnedFromTemplateId: "t1", isDeleted: true)
        let ach = achievementTask("ach1", referencedTemplateId: "t1", requiredCount: 3)
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, s1, s2, s3, s4],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }

    func testComputeBoardStats_TemplateBoundary_StartDateEqualsParentStart_Counts() {
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let s1 = board("s1", status: "completed", startDate: "2026-04-01T00:00:00.000Z", spawnedFromTemplateId: "t1")
        let ach = achievementTask("ach1", referencedTemplateId: "t1", requiredCount: 1)
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, s1],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }

    func testComputeBoardStats_TemplateBoundary_StartDateEqualsParentEnd_Counts() {
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let s1 = board("s1", status: "completed", startDate: "2026-04-30T23:59:59.000Z", spawnedFromTemplateId: "t1")
        let ach = achievementTask("ach1", referencedTemplateId: "t1", requiredCount: 1)
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, s1],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }

    // MARK: - Phase 6.3: trigger + count

    func testComputeBoardStats_BingoTrigger_OnSpecificBoard_LinesCompletedSuffices() {
        // trigger=bingo on specific board: cell completes when the
        // referenced board has linesCompleted>0 (no need for full
        // greenlog).
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let ref = boardWithLinesCompleted("ref", status: "active", linesCompleted: 1)
        let ach = achievementTask("ach1", referencedBoardId: "ref", achievementTrigger: .bingo)
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, ref],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }

    func testComputeBoardStats_BingoTrigger_OnSpecificBoard_NoBingoMeansIncomplete() {
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let ref = boardWithLinesCompleted("ref", status: "active", linesCompleted: 0)
        let ach = achievementTask("ach1", referencedBoardId: "ref", achievementTrigger: .bingo)
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, ref],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    func testComputeBoardStats_BingoTrigger_OnTemplate_CountsSpawnsWithLinesCompleted() {
        // 2 spawns, both have linesCompleted>0 → met=2 >= required=2 → complete.
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let s1 = boardWithLinesCompleted("s1", status: "active", startDate: "2026-04-08T00:00:00.000Z", spawnedFromTemplateId: "t1", linesCompleted: 1)
        let s2 = boardWithLinesCompleted("s2", status: "active", startDate: "2026-04-15T00:00:00.000Z", spawnedFromTemplateId: "t1", linesCompleted: 2)
        let ach = achievementTask(
            "ach1",
            referencedTemplateId: "t1",
            achievementTrigger: .bingo,
            requiredCount: 2
        )
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, s1, s2],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }

    func testComputeBoardStats_RequiredCountGreaterThanInWindow_CellIncomplete() {
        // User asked for 3 bingos but only 2 spawns exist — cell stays
        // incomplete until a 3rd spawn lands AND hits the trigger.
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let s1 = boardWithLinesCompleted("s1", status: "completed", startDate: "2026-04-08T00:00:00.000Z", spawnedFromTemplateId: "t1", linesCompleted: 1)
        let s2 = boardWithLinesCompleted("s2", status: "completed", startDate: "2026-04-15T00:00:00.000Z", spawnedFromTemplateId: "t1", linesCompleted: 1)
        let ach = achievementTask(
            "ach1",
            referencedTemplateId: "t1",
            achievementTrigger: .bingo,
            requiredCount: 3
        )
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, s1, s2],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 0)
    }

    /// Helper for trigger-bingo tests: the default `board()` helper
    /// doesn't override `linesCompleted`. Inline a richer builder.
    private func boardWithLinesCompleted(
        _ id: String,
        status: String,
        startDate: String = "2026-04-01T00:00:00.000Z",
        spawnedFromTemplateId: String? = nil,
        linesCompleted: Int
    ) -> Board {
        var dict: [String: Any] = [
            "id": id,
            "userId": "u",
            "name": id,
            "status": status,
            "boardSize": 3,
            "timeframe": "monthly",
            "startDate": startDate,
            "endDate": "2026-04-30T23:59:59.000Z",
            "centerSquareType": "none",
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": linesCompleted,
            "createdAt": "2026-04-23T00:00:00.000Z",
            "updatedAt": "2026-04-23T00:00:00.000Z",
            "version": 1,
            "isDeleted": false,
        ]
        if let tid = spawnedFromTemplateId { dict["spawnedFromTemplateId"] = tid }
        let jsonData = try! JSONEncoder().encode([String]())
        dict["completedLineIds"] = String(data: jsonData, encoding: .utf8)!
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - Phase 6.3: bad-data precedence

    func testComputeBoardStats_BothFieldsSet_ReferencedBoardWins() {
        // Zod refinement rejects rows with both set, but a malicious remote
        // payload or older client could still produce one. Derivation must
        // be deterministic: the more-specific reference wins.
        let parent = board("parent", boardSize: 3, centerSquareType: .none)
        let ref = board("ref", status: "completed")
        let ach = achievementTask(
            "ach1",
            referencedBoardId: "ref",
            referencedTemplateId: "t1"
        )
        let bt = boardTask("parent", "ach1", 0, 0)
        let result = DerivationPass.computeBoardStatsUpdate(
            board: parent,
            boardTasksOnBoard: [bt],
            childrenByCompound: [:],
            taskById: ["ach1": ach],
            allBoards: [parent, ref],
            windowContext: nil
        )
        XCTAssertEqual(result.completedTasks, 1)
    }
}
