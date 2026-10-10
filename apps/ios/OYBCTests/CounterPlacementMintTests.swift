import XCTest
import GRDB
@testable import OYBC

/// docs/SHARED_COUNTER_SETTINGS.md §2 (PR 2) — placing a shared counter mints
/// its per-board copy at the counter's default goal for the board's timeframe,
/// titled through the root's templates; a counter with no defaults places
/// exactly as before. Covers Board Edit (add + Replace via the placement choke
/// points) and the wizard / spawn mint (`planAndMintDerivedRows`: hand-added
/// root and a board-sourced member). Web twin: `counterPlacementDefaults.test.ts`.
final class CounterPlacementMintTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let septStart = "2026-09-01T00:00:00.000Z", septEnd = "2026-09-30T00:00:00.000Z"

    private func derived(_ board: String) -> String { BoardSources.derivedTaskId(boardId: board, rootTaskId: "root") }

    /// A 100-mile counter root; SEPT ("b1") is a MONTHLY board.
    private func root(goals: CounterTimeframeGoals? = CounterTimeframeGoals(monthly: 30), plural: String? = "Run #N mi") -> Task {
        var t = K.task("root", maxCount: 100, title: "Run 100 miles")
        t.timeframeGoals = goals
        t.titlePluralTemplate(plural)
        return t
    }

    private func makeDb(root: Task) throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(root)
        try db.saveBoard(K.board(id: "b1", startDate: septStart, endDate: septEnd, size: 3))
        return db
    }

    // MARK: - Board Edit (placement choke points)

    func test_add_rootWithDefault_mintsCopyAtDefault_titledFromTemplate() throws {
        let db = try makeDb(root: root())
        let bt = try db.addBoardTaskToBoard("b1", taskId: "root", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, derived("b1"))
        let row = try XCTUnwrap(K.fetchTask(db, derived("b1")))
        XCTAssertEqual(row.maxCount, 30)
        XCTAssertEqual(row.title, "Run 30 mi")
        XCTAssertEqual(row.sharedCounterId, "root")
        XCTAssertTrue(BoardSources.isWindowStampedForBoard(row, board: try XCTUnwrap(db.fetchBoard(id: "b1"))))
    }

    func test_replace_rootWithDefault_copyCarriesDefault() throws {
        let db = try makeDb(root: root())
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        try db.updateBoardTaskAndCascade(boardTaskId: "bt", newTaskId: "root")
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").first?.taskId, derived("b1"))
        XCTAssertEqual(try K.fetchTask(db, derived("b1"))?.maxCount, 30)
    }

    func test_add_rootWithoutDefaults_placesRootAsBefore() throws {
        let db = try makeDb(root: root(goals: nil))
        XCTAssertEqual(try db.addBoardTaskToBoard("b1", taskId: "root", position: (row: 0, col: 0)).taskId, "root")
        XCTAssertNil(try K.fetchTask(db, derived("b1")))
    }

    func test_add_defaultEqualToRootGoal_placesRoot() throws {
        let db = try makeDb(root: root(goals: CounterTimeframeGoals(monthly: 100)))
        XCTAssertEqual(try db.addBoardTaskToBoard("b1", taskId: "root", position: (row: 0, col: 0)).taskId, "root")
    }

    func test_add_revivedCopy_keepsItsOwnGoal() throws {
        let db = try makeDb(root: root())
        _ = try db.addBoardTaskToBoard("b1", taskId: "root", position: (row: 0, col: 0))
        try db.write { d in
            try d.execute(sql: "UPDATE tasks SET maxCount = 12, isDeleted = 1 WHERE id = ?", arguments: [self.derived("b1")])
            try d.execute(sql: "UPDATE board_tasks SET isDeleted = 1 WHERE boardId = 'b1'")
        }
        let bt = try db.addBoardTaskToBoard("b1", taskId: "root", position: (row: 0, col: 1))
        XCTAssertEqual(bt.taskId, derived("b1"))
        let row = try XCTUnwrap(K.fetchTask(db, derived("b1")))
        XCTAssertFalse(row.isDeleted)
        XCTAssertEqual(row.maxCount, 12)
    }

    func test_add_linkedTask_keepsOwnGoal_titleFromRootTemplate() throws {
        let db = try makeDb(root: root())
        try db.saveTask(K.task("hub", maxCount: 10, sharedCounterId: "root", title: "Run 10 miles"))
        let bt = try db.addBoardTaskToBoard("b1", taskId: "hub", position: (row: 0, col: 0))
        let row = try XCTUnwrap(K.fetchTask(db, bt.taskId))
        XCTAssertEqual(bt.taskId, derived("b1"))
        XCTAssertEqual(row.maxCount, 10)
        XCTAssertEqual(row.title, "Run 10 mi")
    }

    // MARK: - Wizard / spawn mint

    private let weekStart = "2026-09-07T00:00:00", weekEnd = "2026-09-13T23:59:59"

    private func mint(
        _ database: AppDatabase, selected: [String], manual: [String], supplies: [BoardSources.ExpandedSupply] = [],
        tasksById: [String: Task], sourceWindows: [String: BoardSources.BoardWindow] = [:]
    ) throws -> (placementIds: [String], minted: BoardSources.DerivedRows) {
        try database.write { db in
            try AppDatabase.planAndMintDerivedRows(
                db: db, boardId: "wk", userId: K.userId, now: "2026-09-07T08:00:00.000Z",
                selectedIds: selected, supplies: supplies, manualTaskIds: manual, manualTaskVary: [:],
                window: .init(timeframe: .weekly, startDate: self.weekStart, endDate: self.weekEnd), mode: .oneOff,
                tasksById: tasksById, childrenByCompoundId: [:], sourceWindowByTaskId: sourceWindows,
                events: try TaskEvent.fetchAll(db)
            )
        }
    }

    func test_wizardHandAdd_rootWithWeeklyDefault_mintsCopyAtDefault() throws {
        var r = root(goals: CounterTimeframeGoals(weekly: 7))
        r.titleTemplateSingular = "Run #N mile"
        let db = try makeDb(root: r)
        let out = try mint(db, selected: ["root"], manual: ["root"], tasksById: ["root": r])
        let copyId = BoardSources.derivedTaskId(boardId: "wk", rootTaskId: "root")
        XCTAssertEqual(out.placementIds, [copyId])
        let row = try XCTUnwrap(K.fetchTask(db, copyId))
        XCTAssertEqual(row.maxCount, 7)
        XCTAssertEqual(row.title, "Run 7 mi")
    }

    func test_wizardHandAdd_rootWithoutDefaults_placedAsBefore() throws {
        let r = root(goals: nil)
        let db = try makeDb(root: r)
        let out = try mint(db, selected: ["root"], manual: ["root"], tasksById: ["root": r])
        XCTAssertEqual(out.placementIds, ["root"])
        XCTAssertTrue(out.minted.tasks.isEmpty)
    }

    func test_sourcePull_consultsRootDefaultBeforeProRating() throws {
        let r = root(goals: CounterTimeframeGoals(weekly: 4))
        let db = try makeDb(root: r)
        let member = K.task("monthCopy", maxCount: 30, sharedCounterId: "root", title: "Run 30 miles")
        try db.saveTask(member)
        let supply = BoardSources.ExpandedSupply(
            source: BoardSource(sourceId: "b1", kind: .board), supplyTaskIds: ["monthCopy"], partOf: [:]
        )
        // Only the member is in `tasksById` — the root comes from the database.
        let out = try mint(
            db, selected: ["monthCopy"], manual: [], supplies: [supply], tasksById: ["monthCopy": member],
            sourceWindows: ["monthCopy": .init(timeframe: .monthly, startDate: septStart, endDate: septEnd)]
        )
        let copyId = BoardSources.derivedTaskId(boardId: "wk", rootTaskId: "root")
        XCTAssertEqual(out.placementIds, [copyId])
        // Pro-rating alone would give ceil(30 × 7 / 30) = 7.
        XCTAssertEqual(try K.fetchTask(db, copyId)?.maxCount, 4)
        XCTAssertEqual(try K.fetchTask(db, copyId)?.title, "Run 4 mi")
    }
}

private extension Task {
    /// Sets the stored plural template (a test-only shorthand).
    mutating func titlePluralTemplate(_ value: String?) { titleTemplatePlural = value }
}
