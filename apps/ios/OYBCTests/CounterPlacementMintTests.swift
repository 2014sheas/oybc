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

    func test_add_rootWithDefault_writesTargetOverride_titledFromTemplate() throws {
        let db = try makeDb(root: root())
        let bt = try db.addBoardTaskToBoard("b1", taskId: "root", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, "root", "slice 3a: the root itself is placed, never a copy")
        XCTAssertEqual(bt.targetOverride, 30)
        XCTAssertEqual(bt.targetKind, .discrete)
        XCTAssertNil(try K.fetchTask(db, derived("b1")), "no per-board copy is minted")
        let stored = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first)
        XCTAssertEqual(stored.targetOverride, 30, "persisted, not just returned")
        let rootRow = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(PlacementParams.apply(rootRow, placement: stored).title, "Run 30 mi")
        XCTAssertEqual(rootRow.maxCount, 100, "the library root keeps its own goal")
    }

    func test_replace_rootWithDefault_placementCarriesDefault() throws {
        let db = try makeDb(root: root())
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        try db.updateBoardTaskAndCascade(boardTaskId: "bt", newTaskId: "root")
        let placed = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first)
        XCTAssertEqual(placed.taskId, "root")
        XCTAssertEqual(placed.targetOverride, 30)
        XCTAssertNil(try K.fetchTask(db, derived("b1")))
    }

    /// A swap drops the OLD task's parameters (written as explicit NULLs).
    func test_replace_dropsTheOldPlacementsParameters() throws {
        let db = try makeDb(root: root(goals: nil))
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveTask(K.task("next", maxCount: 8))
        var bt = K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3)
        bt.targetOverride = 9
        bt.targetKind = .discrete
        bt.titleOverride = "Custom"
        try db.saveBoardTask(bt)
        try db.updateBoardTaskAndCascade(boardTaskId: "bt", newTaskId: "next")
        let placed = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first)
        XCTAssertEqual(placed.taskId, "next")
        XCTAssertNil(placed.targetOverride)
        XCTAssertNil(placed.targetKind)
        XCTAssertNil(placed.titleOverride)
    }

    func test_add_rootWithoutDefaults_placesRootAsBefore() throws {
        let db = try makeDb(root: root(goals: nil))
        let bt = try db.addBoardTaskToBoard("b1", taskId: "root", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, "root")
        XCTAssertNil(bt.targetOverride)
        XCTAssertNil(try K.fetchTask(db, derived("b1")))
    }

    func test_add_defaultEqualToRootGoal_placesRootWithoutOverride() throws {
        let db = try makeDb(root: root(goals: CounterTimeframeGoals(monthly: 100)))
        let bt = try db.addBoardTaskToBoard("b1", taskId: "root", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, "root")
        XCTAssertNil(bt.targetOverride)
    }

    /// Explicit parameters passed by Board Edit win over the default rule.
    func test_add_explicitParameters_winOverTheDefaultRule() throws {
        let db = try makeDb(root: root())
        let bt = try db.addBoardTaskToBoard(
            "b1", taskId: "root", position: (row: 0, col: 0), targetOverride: 12, targetKind: .discrete,
            titleOverride: "Twelve"
        )
        XCTAssertEqual(bt.targetOverride, 12)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").first?.titleOverride, "Twelve")
    }

    func test_add_linkedTask_isPlacedAsIs_withNoParameters() throws {
        let db = try makeDb(root: root())
        try db.saveTask(K.task("hub", maxCount: 10, sharedCounterId: "root", title: "Run 10 miles"))
        let bt = try db.addBoardTaskToBoard("b1", taskId: "hub", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, "hub")
        XCTAssertNil(bt.targetOverride)
        XCTAssertNil(try K.fetchTask(db, derived("b1")))
        XCTAssertEqual(try K.fetchTask(db, "hub")?.maxCount, 10)
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

    func test_poolPull_rootMintsAtItsWeeklyDefault() throws {
        let r = root(goals: CounterTimeframeGoals(weekly: 3))
        let db = try makeDb(root: r)
        let supply = BoardSources.ExpandedSupply(
            source: BoardSource(sourceId: "pool-1", kind: .pool), supplyTaskIds: ["root"], partOf: [:]
        )
        let out = try mint(db, selected: ["root"], manual: [], supplies: [supply], tasksById: ["root": r])
        let copyId = BoardSources.derivedTaskId(boardId: "wk", rootTaskId: "root")
        XCTAssertEqual(out.placementIds, [copyId])
        XCTAssertEqual(try K.fetchTask(db, copyId)?.maxCount, 3)
        XCTAssertEqual(try K.fetchTask(db, copyId)?.title, "Run 3 mi")
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
