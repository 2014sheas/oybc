import GRDB
import XCTest
@testable import OYBC

/// The read-cost half of the board-log lag fix: per-apply derived state (one `taskMap` per
/// apply, no database read while rendering), the in-memory sealed-immunity set equalling the
/// database-derived one, and one structure fetch per shared-counter cascade.
@MainActor
final class BoardLogLagReadsTests: XCTestCase {

    private let userId = "u1"
    private let sealedStart = "2026-07-01T00:00:00.000Z", sealedEnd = "2026-07-02T00:00:00.000Z"
    private let sealedAt = "2026-07-02T06:00:00.000Z"
    private let liveStart = "2026-07-03T00:00:00.000Z", liveEnd = "2026-07-09T23:59:59.999Z"
    private let inSealed = "2026-07-01T12:00:00.000Z", inLive = "2026-07-04T12:00:00.000Z"

    // MARK: Fixtures

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults), createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func board(_ id: String, start: String, end: String, sealedAt: String? = nil) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": id, "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": Timeframe.daily.rawValue, "startDate": start, "endDate": end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false, "totalTasks": 9,
            "completedTasks": 0, "linesCompleted": 0, "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        return try! JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func task(_ id: String, type: TaskType = .normal) -> Task {
        var t = Task(
            id: id, userId: userId, title: id, type: type, action: nil, unit: nil, maxCount: nil,
            totalCompletions: 0, totalInstances: 0, createdAt: sealedStart, updatedAt: sealedStart, version: 1, isDeleted: false
        )
        if type == .compound { t.operatorType = .and }
        return t
    }

    private func place(_ db: AppDatabase, _ board: String, _ taskId: String, cell: Int) throws {
        try db.saveBoardTask(BoardTask(
            id: "bt-\(board)-\(taskId)", boardId: board, taskId: taskId, row: cell / 3, col: cell % 3, isCenter: false,
            createdAt: sealedStart, updatedAt: sealedStart, lastSyncedAt: nil, version: 1
        ))
    }

    private func completion(_ db: AppDatabase, _ taskId: String, at: String, boardId: String? = nil, createdAt: String? = nil, deleted: Bool = false) throws {
        try db.write { d in
            try TaskEvent(
                id: UUID().uuidString, userId: self.userId, taskId: taskId, kind: .completion, delta: nil, occurredAt: at,
                boardId: boardId, createdAt: createdAt ?? at, updatedAt: at, lastSyncedAt: nil, version: 1,
                isDeleted: deleted, deletedAt: deleted ? at : nil
            ).insert(d)
        }
    }

    /// Sealed board S (cells: nA..nE, compound P holding nF) and live board L placing every task directly.
    private func seedSealedWorkspace(_ db: AppDatabase) throws {
        try seedUser(db)
        try db.saveBoard(board("S", start: sealedStart, end: sealedEnd, sealedAt: sealedAt))
        try db.saveBoard(board("L", start: sealedStart, end: liveEnd)) // overlaps S: the sealed-window completions read done here
        for id in ["nA", "nB", "nC", "nD", "nE", "nF"] { try db.saveTask(task(id)) }
        try db.saveTask(task("P", type: .compound))
        try db.write { d in
            let now = self.sealedStart
            try CompoundChild(id: "P-nF", compoundTaskId: "P", childTaskId: "nF", childIndex: 0, createdAt: now, updatedAt: now, version: 1, isDeleted: false).save(d)
        }
        for (i, id) in ["nA", "nB", "nC", "nD", "nE", "P"].enumerated() { try place(db, "S", id, cell: i) }
        for (i, id) in ["nA", "nB", "nC", "nD", "nE", "nF"].enumerated() { try place(db, "L", id, cell: i) }
        try completion(db, "nA", at: inSealed)                                   // held only by the sealed window
        try completion(db, "nB", at: inSealed)                                   // sealed...
        try completion(db, "nB", at: inLive, boardId: "L")                       // ...plus a live one
        try completion(db, "nC", at: inSealed, boardId: "S", createdAt: "2026-07-03T00:00:00.000Z") // a late log made after the seal
        // nD: no completion at all
        try completion(db, "nE", at: inSealed, deleted: true)                    // a tombstone is not a completion
        try completion(db, "nF", at: inSealed)                                   // sealed only THROUGH compound P
    }

    private let allIds = ["nA", "nB", "nC", "nD", "nE", "nF", "P"]

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }

    private func loadedVM(_ db: AppDatabase, board: String) -> BoardPlayViewModel {
        let vm = BoardPlayViewModel(boardId: board, userId: userId, database: db)
        vm.reload()
        _ = waitUntil { vm.board?.id == board && !vm.allTasks.isEmpty }
        return vm
    }

    private func trace(_ db: AppDatabase) -> () -> [String] {
        var log: [String] = []
        try? db.dbQueue.inDatabase { $0.trace { log.append($0.description) } }
        return { log }
    }

    // MARK: - Sealed-immunity set (item 3)

    func test_inMemorySealBlockedSet_equalsTheDatabaseDerivedOne() throws {
        let db = try AppDatabase.makeTestInstance(); try seedSealedWorkspace(db)
        let expected = Set(try allIds.filter { try db.isUncompleteBlockedBySeal(taskId: $0) })
        XCTAssertEqual(expected, ["nA", "nF"], "fixture sanity: nB has a live completion, nC is a late log, nD/nE none")

        let tasks = try db.fetchTasks(userId: userId)
        let inMemory = SealBlocked.blockedTaskIds(
            candidateIds: Set(allIds), boards: try db.fetchBoards(userId: userId), tasks: tasks,
            compoundChildren: try db.fetchAllCompoundChildren(), boardTasks: try db.fetchAllBoardTasks(),
            eventsByTaskId: Dictionary(grouping: try db.fetchNonDeletedTaskEvents(userId: userId), by: \.taskId)
        )
        XCTAssertEqual(inMemory, expected)
        XCTAssertEqual(try db.sealBlockedTaskIds(taskIds: Set(allIds)), expected, "the batched keyed form agrees too")
    }

    func test_noSealedBoards_blocksNothing() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("L", start: liveStart, end: liveEnd))
        try db.saveTask(task("nA")); try place(db, "L", "nA", cell: 0)
        try completion(db, "nA", at: inLive)
        XCTAssertEqual(try db.sealBlockedTaskIds(taskIds: ["nA"]), [])
        XCTAssertFalse(try db.isUncompleteBlockedBySeal(taskId: "nA"))
    }

    func test_theViewModelsSetIsLoadedWithTheReload_andRenderingReadsNoDatabase() throws {
        let db = try AppDatabase.makeTestInstance(); try seedSealedWorkspace(db)
        let vm = loadedVM(db, board: "L")
        XCTAssertEqual(vm.derived.sealBlockedTaskIds, ["nA", "nF"])

        // The hold menu of a done Normal square reads the set — and nothing else.
        let btA = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "nA" })
        let statements = trace(db)
        let render = vm.placementRender(for: btA)
        guard case let .normal(isDone, sealBlocked)? = vm.menuInput(for: render)?.body else { return XCTFail("normal menu") }
        XCTAssertTrue(isDone)
        XCTAssertTrue(sealBlocked)
        let btB = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "nB" })
        guard case let .normal(_, blockedB)? = vm.menuInput(for: vm.placementRender(for: btB))?.body else { return XCTFail("normal menu") }
        XCTAssertFalse(blockedB)
        XCTAssertEqual(statements(), [], "no database read while the menu / cells build")
    }

    // MARK: - Derived state (item 2)

    func test_taskMapAndGroupingsAreBuiltPerApply_notPerRead() throws {
        let db = try AppDatabase.makeTestInstance(); try seedSealedWorkspace(db)
        let vm = loadedVM(db, board: "L")
        let statements = trace(db)

        #if DEBUG
        let before = BoardPlayDerived.taskMapBuilds
        #endif
        for _ in 0..<200 {
            for bt in vm.boardTasks {
                _ = vm.taskMap[bt.taskId]
                _ = vm.compoundChildrenByCompound
                _ = vm.sharedCounterSourceId(for: vm.taskMap[bt.taskId]!)
                let render = vm.placementRender(for: bt)
                _ = vm.displayCount(of: render)
                _ = vm.menuInput(for: render)
            }
        }
        #if DEBUG
        XCTAssertEqual(BoardPlayDerived.taskMapBuilds, before, "reads never rebuild the map")
        #endif
        XCTAssertEqual(statements(), [])

        #if DEBUG
        let applies = vm.applyCount
        let buildsBefore = BoardPlayDerived.taskMapBuilds
        vm.reload()
        XCTAssertTrue(waitUntil { vm.applyCount > applies })
        XCTAssertGreaterThanOrEqual(BoardPlayDerived.taskMapBuilds - buildsBefore, 1)
        XCTAssertLessThanOrEqual(BoardPlayDerived.taskMapBuilds - buildsBefore, vm.applyCount - applies, "one map per apply")
        #endif
    }

    func test_sharedCounterSourceId_usesTheLookupSets_withTheSameAnswers() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("L", start: liveStart, end: liveEnd))
        func counting(_ id: String, shared: String? = nil, isCounter: Bool = false) -> Task {
            var t = Task(
                id: id, userId: userId, title: id, type: .counting, action: nil, unit: "pages", maxCount: 10,
                totalCompletions: 0, totalInstances: 0, createdAt: sealedStart, updatedAt: sealedStart, version: 1, isDeleted: false,
                sharedCounterId: shared
            )
            if isCounter { t.isCounter = true }
            return t
        }
        try db.saveTask(counting("root")); try db.saveTask(counting("linked", shared: "root"))
        try db.saveTask(counting("promoted", isCounter: true)); try db.saveTask(counting("plain"))
        try db.saveTask(counting("overridden"))
        try place(db, "L", "overridden", cell: 0)
        try db.write { try $0.execute(sql: "UPDATE board_tasks SET targetOverride = 3 WHERE taskId = 'overridden'") }
        let vm = loadedVM(db, board: "L")
        let id: (String) -> String? = { vm.sharedCounterSourceId(for: vm.taskMap[$0]!) }
        XCTAssertEqual(id("root"), "root", "a root heads its family through a live linked row")
        XCTAssertEqual(id("linked"), "root")
        XCTAssertEqual(id("promoted"), "promoted")
        XCTAssertEqual(id("overridden"), "overridden", "a placement with a target override heads a family")
        XCTAssertNil(id("plain"))
    }

    // MARK: - One structure fetch per cascade (item 4)

    func test_theSharedCounterCascadeFetchesTheStructureOnce() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("L", start: liveStart, end: liveEnd))
        var root = Task(
            id: "root", userId: userId, title: "root", type: .counting, action: nil, unit: "pages", maxCount: 10,
            totalCompletions: 0, totalInstances: 0, createdAt: sealedStart, updatedAt: sealedStart, version: 1, isDeleted: false
        )
        root.isCounter = true
        try db.saveTask(root)
        try db.saveTask(Task(
            id: "linked", userId: userId, title: "linked", type: .counting, action: nil, unit: "pages", maxCount: 10,
            totalCompletions: 0, totalInstances: 0, createdAt: sealedStart, updatedAt: sealedStart, version: 1, isDeleted: false,
            sharedCounterId: "root"
        ))
        try place(db, "L", "linked", cell: 0)
        let statements = trace(db)

        let result = try db.incrementSharedCounter(sourceTaskId: "root", by: 2, boardId: "L", now: "2026-07-05T00:00:00.000Z")

        XCTAssertEqual(result.affectedBoards.map(\.boardId), ["L"], "behaviour unchanged: the credited board")
        let log = statements()
        let fetches: (String) -> Int = { table in log.filter { $0.contains("FROM \"\(table)\"") && !$0.contains("WHERE \"id\"") && !$0.contains("WHERE \"boardId\"") }.count }
        XCTAssertEqual(fetches("board_tasks"), 1, "placements: once for the reach AND the derivation\n\(log.joined(separator: "\n"))")
        XCTAssertEqual(log.filter { $0 == "SELECT * FROM \"tasks\"" }.count, 1, "tasks: no refetch when the counts-toward pass wrote nothing")
        // Links: the cascade's one fetch + the counts-toward pass's own candidate walk.
        XCTAssertEqual(fetches("compound_children"), 2, "links\n\(log.joined(separator: "\n"))")
    }
}
