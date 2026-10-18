import GRDB
import XCTest
@testable import OYBC

/// Task Detail's keyed reads (`scopedPlacementReach`) against the unscoped read they replaced,
/// on a workspace full of unrelated rows, and the coalescing refresh after a write.
@MainActor
final class TaskDetailScopedReadsTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let start = "2026-10-12T00:00:00.000Z", end = "2026-10-18T23:59:59.999Z"

    private func link(_ compound: String, _ child: String, index: Int = 0) -> CompoundChild {
        CompoundChild(
            id: "l-\(compound)-\(child)", compoundTaskId: compound, childTaskId: child, childIndex: index,
            createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func compound(_ id: String) -> Task {
        var c = K.task(id, maxCount: nil)
        c.type = .compound
        c.operatorType = .and
        return c
    }

    /// The pre-scoping implementation, verbatim: every task, link, placement and event in the workspace.
    private func unscoped(_ db: AppDatabase, _ taskId: String) throws -> AppDatabase.TaskDetailPlacements {
        try db.read { db in
            let tasks = try Task.fetchAll(db)
            let links = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
            let boardTasks = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
            let reach = DerivationPass.placementsReachedByTasks(ids: [taskId], tasks: tasks, compoundChildren: links, boardTasks: boardTasks)
            let reachedBoards = reach.boardIds.isEmpty ? [] : try Board.filter(reach.boardIds.contains(Column("id"))).fetchAll(db)
            let taskById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let watches = reach.placements.contains { taskById[$0.memberTaskId]?.type == .achievement }
            let allBoards = watches ? try Board.fetchAll(db) : reachedBoards
            let events = try TaskEvent.filter(Column("isDeleted") == false).fetchAll(db)
            let live = reachedBoards.filter { !$0.isDeleted }
            let rows = TaskPlacementRows.rows(
                taskId: taskId, reach: reach.placements,
                boardsById: Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }), taskById: taskById,
                childrenByCompound: Dictionary(grouping: links, by: \.compoundTaskId),
                eventsByTaskId: Dictionary(grouping: events, by: \.taskId),
                boardTasksByBoard: Dictionary(grouping: boardTasks.filter { reach.boardIds.contains($0.boardId) }, by: \.boardId),
                allBoards: allBoards.filter { !$0.isDeleted }
            )
            return AppDatabase.TaskDetailPlacements(
                ownPlacements: boardTasks.filter { $0.taskId == taskId },
                anchorCandidates: AppDatabase.heroAnchorCandidates(
                    taskId: taskId, reach: reach.placements, taskById: taskById,
                    childrenByCompound: Dictionary(grouping: links, by: \.compoundTaskId)
                ),
                boards: live, rows: rows, taskById: taskById
            )
        }
    }

    private func assertSame(_ db: AppDatabase, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let want = try unscoped(db, id), got = try db.fetchTaskDetailPlacements(taskId: id)
        XCTAssertEqual(got.rows, want.rows, "rows of \(id)", file: file, line: line)
        XCTAssertEqual(got.ownPlacements.map(\.id).sorted(), want.ownPlacements.map(\.id).sorted(), "own placements of \(id)", file: file, line: line)
        XCTAssertEqual(
            got.anchorCandidates.map { "\($0.placement.id)|\($0.childTaskId ?? "-")|\($0.rank)" },
            want.anchorCandidates.map { "\($0.placement.id)|\($0.childTaskId ?? "-")|\($0.rank)" }, "anchors of \(id)", file: file, line: line
        )
        XCTAssertEqual(got.boards.map(\.id).sorted(), want.boards.map(\.id).sorted(), "boards of \(id)", file: file, line: line)
        // Everything the rows need is present (the scoped map is a subset of the full one).
        for (k, v) in got.taskById { XCTAssertEqual(want.taskById[k]?.id, v.id, file: file, line: line) }
    }

    /// A weekly board with a compound (two counting children, one of them linked to a counter
    /// root), a plain counter, an achievement watching a board, plus unrelated noise.
    private func seedWorkspace(_ db: AppDatabase) throws {
        try K.seedUser(db)
        try db.saveBoard(K.board(id: "B1", startDate: start, endDate: end, timeframe: .weekly, size: 3))
        try db.saveBoard(K.board(id: "B2", startDate: start, endDate: end, timeframe: .weekly, size: 3))
        try db.saveBoard(K.board(id: "BS", startDate: "2026-10-05T00:00:00.000Z", endDate: "2026-10-11T23:59:59.999Z", timeframe: .weekly, sealedAt: "2026-10-12T01:00:00.000Z", size: 3))
        var root = K.task("root", maxCount: nil); root.isCounter = true
        try db.saveTask(root)
        try db.saveTask(K.task("linked", maxCount: 10, sharedCounterId: "root", baseline: 0))
        try db.saveTask(K.task("kid", maxCount: 4))
        try db.saveTask(K.task("plain", maxCount: 6))
        try db.saveTask(compound("P"))
        try db.saveTask(compound("Outer"))
        var ach = K.task("ach", maxCount: nil); ach.type = .achievement; ach.referencedBoardId = "B1"; ach.achievementTrigger = .greenlog
        try db.saveTask(ach)
        try db.write { d in
            try self.link("P", "kid").save(d)
            try self.link("P", "linked", index: 1).save(d)
            try self.link("Outer", "P").save(d)
        }
        try db.saveBoardTask(K.placement(id: "b1-plain", boardId: "B1", taskId: "plain", cell: 0, size: 3))
        try db.saveBoardTask(K.placement(id: "b1-P", boardId: "B1", taskId: "P", cell: 1, size: 3))
        try db.saveBoardTask(K.placement(id: "b2-linked", boardId: "B2", taskId: "linked", cell: 0, size: 3))
        try db.saveBoardTask(K.placement(id: "b2-outer", boardId: "B2", taskId: "Outer", cell: 1, size: 3))
        try db.saveBoardTask(K.placement(id: "b2-ach", boardId: "B2", taskId: "ach", cell: 2, size: 3))
        try db.saveBoardTask(K.placement(id: "bs-kid", boardId: "BS", taskId: "kid", cell: 0, size: 3))
        try K.addIncrement(db, taskId: "root", delta: 3, occurredAt: "2026-10-14T10:00:00.000Z")
        try K.addIncrement(db, taskId: "kid", delta: 4, occurredAt: "2026-10-15T10:00:00.000Z")
        try K.addIncrement(db, taskId: "plain", delta: 2, occurredAt: "2026-10-15T10:00:00.000Z")
        // Noise the reach can never touch.
        for i in 0..<40 {
            try db.saveTask(K.task("noise\(i)", maxCount: 5))
            try db.saveBoardTask(K.placement(id: "bn\(i)", boardId: i.isMultiple(of: 2) ? "B1" : "B2", taskId: "noise\(i)", cell: 3 + (i % 6), size: 3))
            try K.addIncrement(db, taskId: "noise\(i)", delta: 1, occurredAt: "2026-10-15T10:00:00.000Z")
        }
    }

    func test_scopedPlacementRead_equalsTheUnscopedOne_forEveryKindOfTask() throws {
        let db = try AppDatabase.makeTestInstance(); try seedWorkspace(db)
        for id in ["root", "linked", "kid", "plain", "P", "Outer", "ach", "noise3", "nope"] { try assertSame(db, id) }
    }

    func test_scopedRead_doesNotTouchUnrelatedRows() throws {
        let db = try AppDatabase.makeTestInstance(); try seedWorkspace(db)
        var log: [String] = []
        try db.dbQueue.inDatabase { $0.trace { log.append($0.description) } }
        _ = try db.fetchTaskDetailPlacements(taskId: "plain")
        XCTAssertFalse(log.contains { $0 == "SELECT * FROM \"tasks\"" || $0 == "SELECT * FROM \"board_tasks\"" || $0 == "SELECT * FROM \"task_events\"" },
                       "no whole-table reads:\n\(log.joined(separator: "\n"))")
        XCTAssertFalse(log.contains { $0.contains("FROM \"task_events\"") && !$0.contains("\"taskId\"") }, "events are keyed by task")
    }

    func test_sealBlockedForTaskDetail_matchesPerTaskReads() throws {
        let db = try AppDatabase.makeTestInstance(); try seedWorkspace(db)
        // "kid" completed inside the sealed board's window → held by the seal... as a counting task it owns no
        // completion events; the rule still agrees with the per-task read for every id.
        let ids = ["root", "linked", "kid", "plain", "P"]
        let expected = Set(try ids.filter { try db.isUncompleteBlockedBySeal(taskId: $0) })
        XCTAssertEqual(try db.sealBlockedTaskIds(taskIds: Set(ids)), expected)
    }

    // MARK: - Refresh coalescing

    func test_aRefreshRequestedMidFetch_runsOnceMore_soTheLastWriteIsReflected() async throws {
        let db = try AppDatabase.makeTestInstance(); try seedWorkspace(db)
        let vm = TaskDetailViewModel(taskId: "plain", database: db, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        await vm.load()
        for _ in 0..<500 where vm.model == nil { try await _Concurrency.Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(vm.model)

        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = 0
        vm.snapshotFetcher = { id, database, includeUserTasks in
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            if n == 1 { started.signal(); release.wait() } // hold the first fetch in flight
            return try TaskDetailViewModel.fetchSnapshot(taskId: id, database: database, includeUserTasks: includeUserTasks)
        }

        async let first: Void = vm.refreshAfterWrite()
        await _Concurrency.Task.detached { started.wait() }.value
        await vm.refreshAfterWrite() // arrives mid-fetch: used to be dropped
        release.signal()
        await first

        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(calls, 2, "the dropped request is replayed once the in-flight fetch lands")
    }

    func test_aPostWriteRefreshKeepsTheEditSheetsTaskList() async throws {
        let db = try AppDatabase.makeTestInstance(); try seedWorkspace(db)
        let vm = TaskDetailViewModel(taskId: "P", database: db, now: { Date(timeIntervalSince1970: 1_792_000_000) })
        await vm.load()
        let loadedCount = vm.userTasks.count
        XCTAssertGreaterThan(loadedCount, 40)
        var asked: [Bool] = []
        let lock = NSLock()
        vm.snapshotFetcher = { id, database, includeUserTasks in
            lock.lock(); asked.append(includeUserTasks); lock.unlock()
            return try TaskDetailViewModel.fetchSnapshot(taskId: id, database: database, includeUserTasks: includeUserTasks)
        }
        await vm.refreshAfterWrite()
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(asked, [false], "a write refresh doesn't reread the user's whole library")
        XCTAssertEqual(vm.userTasks.count, loadedCount)
    }
}
