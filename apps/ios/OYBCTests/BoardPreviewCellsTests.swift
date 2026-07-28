import XCTest
@testable import OYBC

/// `BoardPreviewCells.build` bugfix (bugfix/board-preview-real-cells): the
/// board-card mini preview must render the TRUE grid — real boardSize, real
/// BoardTask placement, real per-cell completion via the same derivation
/// `BoardPlayView.risoPlaySquare` uses — never a fixed-5x5 scattered
/// count-approximation. Mirrors
/// `apps/web/src/components/home/__tests__/boardPreviewCells.test.ts`
/// case-for-case (the ACHIEVEMENT case is additional — iOS's play grid
/// live-derives it, unlike web's lifetime-cache fallback; see
/// `BoardPreviewCells.swift`'s doc comment).
final class BoardPreviewCellsTests: XCTestCase {

    private let userId = "user-1"
    private let start = "2026-07-01T00:00:00.000Z"

    // MARK: - Fixtures

    private func makeBoard(
        id: String = "board-1",
        boardSize: Int = 3,
        startDate: String? = nil,
        centerSquareType: CenterSquareType = .none,
        sealedAt: String? = nil,
        sealedCompletedCells: [Int]? = nil
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "B", "status": BoardStatus.active.rawValue,
            "boardSize": boardSize, "timeframe": Timeframe.daily.rawValue,
            "startDate": startDate ?? start,
            "centerSquareType": centerSquareType.rawValue, "isRandomized": false,
            "totalTasks": boardSize * boardSize, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        if let cells = sealedCompletedCells,
           let data = try? JSONEncoder().encode(cells),
           let str = String(data: data, encoding: .utf8) {
            dict["sealedCompletedCells"] = str
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeNormalTask(_ id: String, isCompleted: Bool = false, completedAt: String? = nil) -> Task {
        Task(
            id: id, userId: userId, title: "Task \(id)", type: .normal,
            totalCompletions: 0, totalInstances: 1,
            isCompleted: isCompleted, completedAt: completedAt,
            createdAt: start, updatedAt: start, version: 1, isDeleted: false
        )
    }

    private func makeCountingTask(
        _ id: String, isCompleted: Bool = false, currentCount: Int? = 0,
        sharedCounterId: String? = nil, baseline: Int? = nil
    ) -> Task {
        Task(
            id: id, userId: userId, title: "Counter \(id)", type: .counting,
            action: "Do", unit: "reps", maxCount: 10,
            totalCompletions: 0, totalInstances: 1,
            isCompleted: isCompleted, currentCount: currentCount,
            createdAt: start, updatedAt: start, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId, baseline: baseline
        )
    }

    private func makeCompoundTask(_ id: String, operatorType: OperatorType = .and) -> Task {
        Task(
            id: id, userId: userId, title: "Compound \(id)", type: .compound,
            operatorType: operatorType,
            totalCompletions: 0, totalInstances: 1,
            isCompleted: false,
            createdAt: start, updatedAt: start, version: 1, isDeleted: false
        )
    }

    private func makeAchievementTask(
        _ id: String, trigger: AchievementTrigger = .greenlog,
        referencedBoardId: String? = nil, referencedTemplateId: String? = nil, requiredCount: Int? = nil,
        isCompleted: Bool = false
    ) -> Task {
        Task(
            id: id, userId: userId, title: "Achievement \(id)", type: .achievement,
            referencedBoardId: referencedBoardId, referencedTemplateId: referencedTemplateId,
            achievementTrigger: trigger, requiredCount: requiredCount,
            totalCompletions: 0, totalInstances: 1,
            isCompleted: isCompleted,
            createdAt: start, updatedAt: start, version: 1, isDeleted: false
        )
    }

    private func makeBoardTask(boardId: String, taskId: String, row: Int, col: Int) -> BoardTask {
        BoardTask(
            id: "bt-\(boardId)-\(taskId)", boardId: boardId, taskId: taskId,
            row: row, col: col, isCenter: false,
            createdAt: start, updatedAt: start, version: 1
        )
    }

    private func makeCompoundChild(_ compoundTaskId: String, _ childTaskId: String, _ childIndex: Int) -> CompoundChild {
        CompoundChild(
            id: "cc-\(compoundTaskId)-\(childTaskId)", compoundTaskId: compoundTaskId, childTaskId: childTaskId,
            childIndex: childIndex, createdAt: start, updatedAt: start, version: 1, isDeleted: false
        )
    }

    private func completionEvent(_ id: String, taskId: String, occurredAt: String) -> TaskEvent {
        TaskEvent(
            id: id, userId: userId, taskId: taskId, kind: .completion, delta: nil,
            occurredAt: occurredAt, boardId: nil, createdAt: occurredAt, updatedAt: occurredAt,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    // MARK: - Tests

    func testRendersRealBoardTaskPositionsNotFirstNCountFill() {
        let board = makeBoard(boardSize: 3)
        let done = makeNormalTask("t-done", isCompleted: true, completedAt: start)
        let notDone = makeNormalTask("t-not-done")
        let boardTasks = [makeBoardTask(boardId: board.id, taskId: done.id, row: 2, col: 0),
                           makeBoardTask(boardId: board.id, taskId: notDone.id, row: 2, col: 2)]
        let taskMap = [done.id: done, notDone.id: notDone]
        let eventsByTaskId = [done.id: [completionEvent("e-done", taskId: done.id, occurredAt: start)]]

        let result = BoardPreviewCells.build(
            board: board, boardTasks: boardTasks, taskMap: taskMap,
            childrenByCompound: [:], eventsByTaskId: eventsByTaskId
        )

        XCTAssertEqual(result.size, 3)
        XCTAssertEqual(result.cells.count, 9)
        for i in 0..<6 { XCTAssertEqual(result.cells[i], .empty, "index \(i)") }
        XCTAssertEqual(result.cells[6], .task(completed: true)) // row2,col0
        XCTAssertEqual(result.cells[7], .empty) // row2,col1 — unplaced
        XCTAssertEqual(result.cells[8], .task(completed: false)) // row2,col2
    }

    func testEmptyCellsForUnplacedPositions() {
        let board = makeBoard(boardSize: 3)
        let result = BoardPreviewCells.build(board: board, boardTasks: [], taskMap: [:], childrenByCompound: [:], eventsByTaskId: [:])
        XCTAssertEqual(result.cells.count, 9)
        XCTAssertTrue(result.cells.allSatisfy { $0 == .empty })
    }

    func testDerivesSizeFromBoardSize() {
        for size in [3, 4, 5] {
            let board = makeBoard(boardSize: size)
            let result = BoardPreviewCells.build(board: board, boardTasks: [], taskMap: [:], childrenByCompound: [:], eventsByTaskId: [:])
            XCTAssertEqual(result.size, size)
            XCTAssertEqual(result.cells.count, size * size)
        }
    }

    func testUnplacedFreeCenterOnOddBoardRendersFreeCenter() {
        let board = makeBoard(boardSize: 3, centerSquareType: .free)
        let result = BoardPreviewCells.build(board: board, boardTasks: [], taskMap: [:], childrenByCompound: [:], eventsByTaskId: [:])
        XCTAssertEqual(result.cells[4], .freeCenter)
        for i in 0..<9 where i != 4 { XCTAssertEqual(result.cells[i], .empty) }
    }

    func testCustomFreeCenterAlsoRendersFreeCenter() {
        let board = makeBoard(boardSize: 5, centerSquareType: .customFree)
        let result = BoardPreviewCells.build(board: board, boardTasks: [], taskMap: [:], childrenByCompound: [:], eventsByTaskId: [:])
        XCTAssertEqual(result.cells[12], .freeCenter)
    }

    func testNoneCenterWithNoTaskIsPlainEmptyCell() {
        let board = makeBoard(boardSize: 3, centerSquareType: .none)
        let result = BoardPreviewCells.build(board: board, boardTasks: [], taskMap: [:], childrenByCompound: [:], eventsByTaskId: [:])
        XCTAssertEqual(result.cells[4], .empty)
    }

    func testLiveBoardResolvesEventOwningTaskAgainstWindowNotLifetimeCache() {
        let board = makeBoard(boardSize: 3, startDate: "2026-07-05T00:00:00.000Z")
        // Lifetime cache says complete, but the only completion event is
        // BEFORE this board's window — should read NOT done (bleed-green regression).
        let task = makeNormalTask("t-1", isCompleted: true, completedAt: "2026-07-01T00:00:00.000Z")
        let boardTasks = [makeBoardTask(boardId: board.id, taskId: task.id, row: 0, col: 0)]
        let eventsByTaskId = [task.id: [completionEvent("e-1", taskId: task.id, occurredAt: "2026-07-01T00:00:00.000Z")]]

        let result = BoardPreviewCells.build(
            board: board, boardTasks: boardTasks, taskMap: [task.id: task],
            childrenByCompound: [:], eventsByTaskId: eventsByTaskId
        )
        XCTAssertEqual(result.cells[0], .task(completed: false))
    }

    func testLiveBoardReadsFreshInWindowEventAsDoneEvenWithStaleLifetimeCache() {
        let board = makeBoard(boardSize: 3, startDate: "2026-07-05T00:00:00.000Z")
        let task = makeNormalTask("t-1", isCompleted: false)
        let boardTasks = [makeBoardTask(boardId: board.id, taskId: task.id, row: 0, col: 0)]
        let eventsByTaskId = [task.id: [completionEvent("e-1", taskId: task.id, occurredAt: "2026-07-05T09:00:00.000Z")]]

        let result = BoardPreviewCells.build(
            board: board, boardTasks: boardTasks, taskMap: [task.id: task],
            childrenByCompound: [:], eventsByTaskId: eventsByTaskId
        )
        XCTAssertEqual(result.cells[0], .task(completed: true))
    }

    func testDerivedCounterStaysOnLifetimeCacheIgnoringWindowEvents() {
        let board = makeBoard(boardSize: 3, startDate: "2026-07-05T00:00:00.000Z")
        let derived = makeCountingTask("t-derived", isCompleted: true, currentCount: 10, sharedCounterId: "source-task", baseline: 0)
        let boardTasks = [makeBoardTask(boardId: board.id, taskId: derived.id, row: 0, col: 0)]

        // No events at all — if incorrectly windowed, zero events would
        // resolve incomplete; the carve-out must still say true.
        let result = BoardPreviewCells.build(
            board: board, boardTasks: boardTasks, taskMap: [derived.id: derived],
            childrenByCompound: [:], eventsByTaskId: [:]
        )
        XCTAssertEqual(result.cells[0], .task(completed: true))
    }

    func testCompoundTaskEvaluatesViaOperatorAgainstWindowedChildren() {
        let board = makeBoard(boardSize: 3, startDate: "2026-07-05T00:00:00.000Z")
        let child1 = makeNormalTask("child-1", isCompleted: true, completedAt: "2026-07-05T09:00:00.000Z")
        let child2 = makeNormalTask("child-2", isCompleted: false)
        let compound = makeCompoundTask("compound-1", operatorType: .and)
        let boardTasks = [makeBoardTask(boardId: board.id, taskId: compound.id, row: 1, col: 1)]
        let childrenByCompound = [compound.id: [makeCompoundChild(compound.id, child1.id, 0), makeCompoundChild(compound.id, child2.id, 1)]]
        let eventsByTaskId = [child1.id: [completionEvent("e-1", taskId: child1.id, occurredAt: "2026-07-05T09:00:00.000Z")]]

        let taskMap = [compound.id: compound, child1.id: child1, child2.id: child2]
        let notDone = BoardPreviewCells.build(
            board: board, boardTasks: boardTasks, taskMap: taskMap,
            childrenByCompound: childrenByCompound, eventsByTaskId: eventsByTaskId
        )
        XCTAssertEqual(notDone.cells[4], .task(completed: false))

        var child2Done = child2
        child2Done.isCompleted = true
        let taskMap2 = [compound.id: compound, child1.id: child1, child2.id: child2Done]
        let eventsByTaskId2 = [
            child1.id: [completionEvent("e-1", taskId: child1.id, occurredAt: "2026-07-05T09:00:00.000Z")],
            child2.id: [completionEvent("e-2", taskId: child2.id, occurredAt: "2026-07-05T10:00:00.000Z")],
        ]
        let done = BoardPreviewCells.build(
            board: board, boardTasks: boardTasks, taskMap: taskMap2,
            childrenByCompound: childrenByCompound, eventsByTaskId: eventsByTaskId2
        )
        XCTAssertEqual(done.cells[4], .task(completed: true))
    }

    func testSealedBoardShortCircuitsToSealedCompletedCellsIgnoringLiveEvents() {
        let board = makeBoard(
            boardSize: 3, startDate: "2026-07-01T00:00:00.000Z",
            sealedAt: "2026-07-02T06:00:00.000Z", sealedCompletedCells: [0]
        )
        // task-a: lifetime cache says INCOMPLETE, but it's in the sealed set.
        let taskA = makeNormalTask("task-a", isCompleted: false)
        // task-b: lifetime cache COMPLETE + an in-window event, but NOT in the sealed set.
        let taskB = makeNormalTask("task-b", isCompleted: true, completedAt: "2026-07-01T12:00:00.000Z")
        let boardTasks = [makeBoardTask(boardId: board.id, taskId: taskA.id, row: 0, col: 0),
                           makeBoardTask(boardId: board.id, taskId: taskB.id, row: 0, col: 1)]
        let taskMap = [taskA.id: taskA, taskB.id: taskB]
        let eventsByTaskId = [taskB.id: [completionEvent("e-1", taskId: taskB.id, occurredAt: "2026-07-01T12:00:00.000Z")]]

        let result = BoardPreviewCells.build(
            board: board, boardTasks: boardTasks, taskMap: taskMap,
            childrenByCompound: [:], eventsByTaskId: eventsByTaskId
        )
        XCTAssertEqual(result.cells[0], .task(completed: true))
        XCTAssertEqual(result.cells[1], .task(completed: false))
    }

    func testBoardTasksBelongingToDifferentBoardAreIgnored() {
        let board = makeBoard(id: "board-1", boardSize: 3)
        let task = makeNormalTask("t-1", isCompleted: true)
        let foreignBoardTask = makeBoardTask(boardId: "other-board", taskId: task.id, row: 0, col: 0)

        let result = BoardPreviewCells.build(
            board: board, boardTasks: [foreignBoardTask], taskMap: [task.id: task],
            childrenByCompound: [:], eventsByTaskId: [:]
        )
        XCTAssertEqual(result.cells[0], .empty)
    }

    func testPlacedBoardTaskWithMissingTaskMapEntryRendersEmpty() {
        let board = makeBoard(boardSize: 3)
        let boardTasks = [makeBoardTask(boardId: board.id, taskId: "missing-task", row: 0, col: 0)]
        let result = BoardPreviewCells.build(board: board, boardTasks: boardTasks, taskMap: [:], childrenByCompound: [:], eventsByTaskId: [:])
        XCTAssertEqual(result.cells[0], .empty)
    }

    // MARK: - Achievement (iOS-specific live cross-board derivation)

    func testAchievementSpecificBoardModeReadsCrossBoardMeets() {
        let parent = makeBoard(id: "parent-board", boardSize: 3, startDate: "2026-07-05T00:00:00.000Z")
        let watched = makeBoard(id: "watched-board", boardSize: 3)
        var watchedCompleted = watched
        watchedCompleted.status = .completed
        let achievement = makeAchievementTask("a-1", trigger: .greenlog, referencedBoardId: watched.id)
        let boardTasks = [makeBoardTask(boardId: parent.id, taskId: achievement.id, row: 0, col: 0)]

        let notMet = BoardPreviewCells.build(
            board: parent, boardTasks: boardTasks, taskMap: [achievement.id: achievement],
            childrenByCompound: [:], eventsByTaskId: [:], allBoardsInWorkspace: [watched]
        )
        XCTAssertEqual(notMet.cells[0], .task(completed: false))

        let met = BoardPreviewCells.build(
            board: parent, boardTasks: boardTasks, taskMap: [achievement.id: achievement],
            childrenByCompound: [:], eventsByTaskId: [:], allBoardsInWorkspace: [watchedCompleted]
        )
        XCTAssertEqual(met.cells[0], .task(completed: true))
    }

    func testAchievementWithNoWorkspaceBoardsDataDefaultsToIncomplete() {
        let parent = makeBoard(id: "parent-board", boardSize: 3)
        let achievement = makeAchievementTask("a-1", trigger: .greenlog, referencedBoardId: "watched-board")
        let boardTasks = [makeBoardTask(boardId: parent.id, taskId: achievement.id, row: 0, col: 0)]

        // allBoardsInWorkspace defaults to [] — the safe default when unavailable.
        let result = BoardPreviewCells.build(
            board: parent, boardTasks: boardTasks, taskMap: [achievement.id: achievement],
            childrenByCompound: [:], eventsByTaskId: [:]
        )
        XCTAssertEqual(result.cells[0], .task(completed: false))
    }
}
