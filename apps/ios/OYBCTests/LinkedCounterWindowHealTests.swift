import XCTest
import GRDB
@testable import OYBC

/// Shared seed helpers for the windowed-linked-counters suites (owner rule
/// 2026-10-01: a counting square accounts only for logs inside its board's
/// window). Plain fixtures — no assertions.
enum LinkedWindowKit {
    static let userId = "u1"

    static func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    static func task(
        _ id: String, maxCount: CountValue? = 10, sharedCounterId: String? = nil,
        startDate: String? = nil, endDate: String? = nil, createdInWizard: Bool = false,
        baseline: CountValue? = nil, currentCount: CountValue? = nil, isCompleted: Bool = false,
        title: String? = nil
    ) -> Task {
        let now = "2026-05-01T00:00:00.000Z"
        return Task(
            id: id, userId: userId, title: title ?? id, description: nil, type: .counting,
            action: "Run", unit: "miles", maxCount: maxCount, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, completedAt: nil, currentCount: currentCount,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: startDate == nil ? nil : .monthly, startDate: startDate, endDate: endDate,
            sharedCounterId: sharedCounterId, baseline: baseline, lastSyncedCount: nil,
            createdInWizard: createdInWizard
        )
    }

    static func board(
        id: String, startDate: String, endDate: String, timeframe: Timeframe = .monthly,
        sealedAt: String? = nil, size: Int = 1
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": id, "status": BoardStatus.active.rawValue,
            "boardSize": size, "timeframe": timeframe.rawValue,
            "startDate": startDate, "endDate": endDate,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": startDate, "updatedAt": startDate, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    static func placement(id: String, boardId: String, taskId: String, cell: Int = 0, size: Int = 1) -> BoardTask {
        let now = "2026-05-01T00:00:00.000Z"
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: cell / size, col: cell % size,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    /// A raw `+delta` increment event on `taskId` at `occurredAt`.
    static func addIncrement(_ db: AppDatabase, taskId: String, delta: CountValue, occurredAt: String) throws {
        try db.write { d in
            try TaskEvent(
                id: UUID().uuidString, userId: userId, taskId: taskId, kind: .increment, delta: delta,
                occurredAt: occurredAt, boardId: nil, createdAt: occurredAt, updatedAt: occurredAt,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).insert(d)
        }
    }

    static func fetchTask(_ db: AppDatabase, _ id: String) throws -> Task? { try db.fetchTask(id: id) }

    static func queue(_ db: AppDatabase, type: String, id: String) throws -> [SyncQueueItem] {
        try db.fetchPendingSyncItems().filter { $0.entityType == type && $0.entityId == id }
    }
}

/// Windowed linked counters — the GRDB v37 / post-pull heal
/// (`AppDatabase+LinkedCounterWindowHeal`). The v37 migration itself is
/// `healLinkedCounterWindowsTx` for every user id; `makeTestInstance()` runs
/// the migrator on an EMPTY database so v37 is a no-op there, and the harness
/// can't re-run a single migration against seeded rows — so these tests drive
/// the Tx helper (the migration's entire body) directly.
@MainActor
final class LinkedCounterWindowHealTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let juneStart = "2026-06-01T00:00:00.000Z", juneEnd = "2026-06-30T00:00:00.000Z"
    private let septStart = "2026-09-01T00:00:00.000Z", septEnd = "2026-09-30T00:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(K.task("root", maxCount: 100, currentCount: 7))
        return db
    }

    private func heal(_ db: AppDatabase) throws -> (stamped: Int, copied: Int, unstamped: Int) {
        try db.healLinkedCounterWindows(userId: K.userId)
    }

    func test_singlePlacement_stampsInPlace() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try db.saveBoardTask(K.placement(id: "bt1", boardId: "J", taskId: "hub"))
        try K.addIncrement(db, taskId: "root", delta: 3, occurredAt: "2026-05-20T00:00:00.000Z")
        try K.addIncrement(db, taskId: "root", delta: 2, occurredAt: "2026-06-10T00:00:00.000Z")

        let r = try heal(db)
        XCTAssertEqual(r.stamped, 1); XCTAssertEqual(r.copied, 0)

        let t = try XCTUnwrap(K.fetchTask(db, "hub"))
        XCTAssertEqual(t.startDate, juneStart); XCTAssertEqual(t.endDate, juneEnd)
        XCTAssertEqual(t.timeframe, .monthly)
        XCTAssertTrue(t.createdInWizard)
        XCTAssertTrue(BoardSources.isWindowStampedDerived(t))
        XCTAssertEqual(t.version, 2)
        XCTAssertEqual(t.baseline, 3, "Σ root increments before the window start")
        let q = try K.queue(db, type: "tasks", id: "hub")
        XCTAssertEqual(q.count, 1); XCTAssertEqual(q[0].operationType, .update)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "J").first?.taskId, "hub", "single placement keeps its id")
    }

    func test_twoPlacements_stampFirst_copyForSecond_repointsPlacement() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try db.saveBoard(K.board(id: "S", startDate: septStart, endDate: septEnd))
        try db.saveBoardTask(K.placement(id: "btJ", boardId: "J", taskId: "hub"))
        try db.saveBoardTask(K.placement(id: "btS", boardId: "S", taskId: "hub"))
        try K.addIncrement(db, taskId: "root", delta: 2, occurredAt: "2026-06-10T00:00:00.000Z")
        try K.addIncrement(db, taskId: "root", delta: 4, occurredAt: "2026-09-10T00:00:00.000Z")

        let r = try heal(db)
        XCTAssertEqual(r.stamped, 1); XCTAssertEqual(r.copied, 1)

        let copyId = BoardSources.derivedTaskId(boardId: "S", rootTaskId: "root")
        let copy = try XCTUnwrap(K.fetchTask(db, copyId))
        XCTAssertTrue(BoardSources.isWindowStampedForBoard(copy, board: try XCTUnwrap(db.fetchBoard(id: "S"))))
        XCTAssertEqual(copy.sharedCounterId, "root"); XCTAssertEqual(copy.maxCount, 10)
        XCTAssertEqual(copy.baseline, 2)
        XCTAssertEqual(try K.queue(db, type: "tasks", id: copyId).first?.operationType, .create)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "S").first?.taskId, copyId)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "J").first?.taskId, "hub")
        let bt = try XCTUnwrap(db.fetchBoardTasks(boardId: "S").first)
        XCTAssertEqual(bt.version, 2)
        XCTAssertEqual(try K.queue(db, type: "boardTasks", id: "btS").first?.operationType, .update)
    }

    /// Owner bug 2026-10-06: a minted copy regenerated its title from fields
    /// whenever `action` was set, dropping a custom name. The kit's default
    /// title is the id ("hub"), which is NOT the auto title for Run / 10 /
    /// miles — so it is custom and the healed copy must keep it verbatim.
    /// Mirrors web `linkedCounterWindowHeal.test.ts` "a healed copy keeps
    /// the linked row's CUSTOM title".
    func test_copy_keepsTheLinkedRowsCustomTitle() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root", title: "Sunday long run"))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try db.saveBoard(K.board(id: "S", startDate: septStart, endDate: septEnd))
        try db.saveBoardTask(K.placement(id: "btJ", boardId: "J", taskId: "hub"))
        try db.saveBoardTask(K.placement(id: "btS", boardId: "S", taskId: "hub"))

        let r = try heal(db)
        XCTAssertEqual(r.copied, 1)

        let copy = try XCTUnwrap(K.fetchTask(db, BoardSources.derivedTaskId(boardId: "S", rootTaskId: "root")))
        XCTAssertEqual(copy.title, "Sunday long run")
        XCTAssertEqual(try XCTUnwrap(K.fetchTask(db, "hub")).title, "Sunday long run")
    }

    /// Control: an AUTO-titled row's copy is titled from its own fields.
    func test_copy_ofAnAutoTitledRow_isTitledFromItsFields() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root", title: "Run 10 miles"))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try db.saveBoard(K.board(id: "S", startDate: septStart, endDate: septEnd))
        try db.saveBoardTask(K.placement(id: "btJ", boardId: "J", taskId: "hub"))
        try db.saveBoardTask(K.placement(id: "btS", boardId: "S", taskId: "hub"))

        _ = try heal(db)

        let copy = try XCTUnwrap(K.fetchTask(db, BoardSources.derivedTaskId(boardId: "S", rootTaskId: "root")))
        XCTAssertEqual(copy.title, "Run 10 miles")
    }

    func test_idempotent_secondRunIsNoOp() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try db.saveBoard(K.board(id: "S", startDate: septStart, endDate: septEnd))
        try db.saveBoardTask(K.placement(id: "btJ", boardId: "J", taskId: "hub"))
        try db.saveBoardTask(K.placement(id: "btS", boardId: "S", taskId: "hub"))
        _ = try heal(db)
        let before = try db.fetchPendingSyncItems().count
        let r = try heal(db)
        XCTAssertEqual(r.stamped, 0); XCTAssertEqual(r.copied, 0)
        XCTAssertEqual(try db.fetchPendingSyncItems().count, before, "a re-run enqueues nothing")
        XCTAssertEqual(try K.fetchTask(db, "hub")?.version, 2)
    }

    func test_tombstonedDeterministicRow_isNotRevived_andPlacementNotRepointed() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try db.saveBoard(K.board(id: "S", startDate: septStart, endDate: septEnd))
        try db.saveBoardTask(K.placement(id: "btJ", boardId: "J", taskId: "hub"))
        try db.saveBoardTask(K.placement(id: "btS", boardId: "S", taskId: "hub"))
        let copyId = BoardSources.derivedTaskId(boardId: "S", rootTaskId: "root")
        var dead = K.task(copyId, sharedCounterId: "root")
        dead.isDeleted = true; dead.deletedAt = "2026-08-01T00:00:00.000Z"; dead.version = 4
        try db.saveTask(dead)

        _ = try heal(db)
        let still = try XCTUnwrap(K.fetchTask(db, copyId))
        XCTAssertTrue(still.isDeleted, "the sweep never revives a tombstone (could lose to a remote tombstone)")
        XCTAssertEqual(still.version, 4)
        XCTAssertTrue(try K.queue(db, type: "tasks", id: copyId).isEmpty)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "S").first?.taskId, "hub", "placement not repointed at a dead row")
        XCTAssertTrue(try K.queue(db, type: "boardTasks", id: "btS").isEmpty)
    }

    func test_boardAlreadyShowsCopy_isSkipped_noDuplicateSquare() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try db.saveBoard(K.board(id: "S", startDate: septStart, endDate: septEnd, size: 2))
        try db.saveBoardTask(K.placement(id: "btJ", boardId: "J", taskId: "hub"))
        try db.saveBoardTask(K.placement(id: "btS", boardId: "S", taskId: "hub", cell: 0, size: 2))
        let copyId = BoardSources.derivedTaskId(boardId: "S", rootTaskId: "root")
        try db.saveTask(K.task(
            copyId, sharedCounterId: "root", startDate: septStart, endDate: septEnd, createdInWizard: true
        ))
        try db.saveBoardTask(K.placement(id: "btS2", boardId: "S", taskId: copyId, cell: 1, size: 2))

        _ = try heal(db)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "S").filter { $0.taskId == copyId }.count, 1)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "S").first { $0.id == "btS" }?.taskId, "hub", "not repointed")
        XCTAssertTrue(try K.queue(db, type: "boardTasks", id: "btS").isEmpty)
    }

    func test_healEnqueues_carryOwnerUid_evenWithNoLiveProvider() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try db.saveBoard(K.board(id: "S", startDate: septStart, endDate: septEnd))
        try db.saveBoardTask(K.placement(id: "btJ", boardId: "J", taskId: "hub"))
        try db.saveBoardTask(K.placement(id: "btS", boardId: "S", taskId: "hub"))
        let before = Set(try db.fetchPendingSyncItems().map(\.id))
        _ = try heal(db)
        let healItems = try db.fetchPendingSyncItems().filter { !before.contains($0.id) }
        XCTAssertFalse(healItems.isEmpty)
        for item in healItems where ["tasks", "boardTasks"].contains(item.entityType) {
            XCTAssertEqual(item.ownerUid, K.userId, "\(item.entityType)/\(item.entityId) must carry the owner")
        }
    }

    /// An AND compound `cmp` whose only child is `childId`, with `cmp` placed on `boardIds`.
    private func seedCompound(_ db: AppDatabase, childId: String, on boardIds: [String]) throws {
        var compound = K.task("cmp", maxCount: nil)
        compound.type = .compound; compound.operatorType = .and; compound.action = nil; compound.unit = nil
        try db.saveTask(compound)
        try db.write { d in
            try CompoundChild(
                id: "lnk", compoundTaskId: "cmp", childTaskId: childId, childIndex: 0,
                createdAt: "2026-05-01T00:00:00.000Z", updatedAt: "2026-05-01T00:00:00.000Z",
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).insert(d)
        }
        for boardId in boardIds {
            try db.saveBoardTask(K.placement(id: "bt-\(boardId)", boardId: boardId, taskId: "cmp"))
        }
    }

    func test_reachedViaCompound_childIsNeverStamped() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try seedCompound(db, childId: "hub", on: ["J"])

        let r = try heal(db)
        XCTAssertEqual(r.stamped, 0)
        XCTAssertEqual(r.unstamped, 0)
        XCTAssertNil(try K.fetchTask(db, "hub")?.startDate)
        XCTAssertTrue(try K.queue(db, type: "tasks", id: "hub").isEmpty)
    }

    /// Incident 2026-10-16: day 1 and day 4 of a daily series place the SAME
    /// compound; the v37 heal had stamped its linked child with day 1. After a
    /// 26-mile log on day 4 the child read 0 of 10 there and was frozen. The
    /// sweep now clears the stamp (three fields, authored), mirrors the root's
    /// lifetime count again and re-derives day 4's board.
    func test_stampedCompoundChild_isUnstamped_andTheLaterBoardReDerives() throws {
        let db = try makeDb()
        let d13s = "2026-10-13T00:00:00.000Z", d13e = "2026-10-13T23:59:59.999Z"
        let d16s = "2026-10-16T00:00:00.000Z", d16e = "2026-10-16T23:59:59.999Z"
        var hub = K.task("hub", maxCount: 10, sharedCounterId: "root", startDate: d13s, endDate: d13e, createdInWizard: true, baseline: 7, currentCount: 7)
        hub.timeframe = .daily
        try db.saveTask(hub)
        try db.saveBoard(K.board(id: "D13", startDate: d13s, endDate: d13e, timeframe: .daily))
        try db.saveBoard(K.board(id: "D16", startDate: d16s, endDate: d16e, timeframe: .daily))
        try seedCompound(db, childId: "hub", on: ["D13", "D16"])
        // The 26-mile log on the counter, made on Oct 16 (root lifetime 7 → 33).
        try K.addIncrement(db, taskId: "root", delta: 26, occurredAt: "2026-10-16T17:30:00.000Z")
        try db.write { d in
            var root = try XCTUnwrap(Task.fetchOne(d, key: "root")); root.currentCount = 33; try root.save(d)
        }

        let r = try heal(db)
        XCTAssertEqual(r.stamped, 0); XCTAssertEqual(r.copied, 0); XCTAssertEqual(r.unstamped, 1)

        let healed = try XCTUnwrap(K.fetchTask(db, "hub"))
        XCTAssertFalse(BoardSources.isWindowStampedDerived(healed))
        XCTAssertNil(healed.timeframe); XCTAssertNil(healed.startDate); XCTAssertNil(healed.endDate)
        XCTAssertTrue(healed.createdInWizard, "not a window mark on its own — left as it was")
        XCTAssertEqual(healed.currentCount, 33, "mirrors the root's lifetime count the freeze had skipped")
        XCTAssertEqual(healed.version, 2)
        XCTAssertEqual(try K.queue(db, type: "tasks", id: "hub").count, 1, "authored: enqueued for peers")
        // Oct 16's compound now completes from the log in ITS window; Oct 13 stays empty.
        XCTAssertEqual(try db.fetchBoard(id: "D16")?.completedTasks, 1)
        XCTAssertEqual(try db.fetchBoard(id: "D13")?.completedTasks, 0)
        // Idempotent.
        let again = try heal(db)
        XCTAssertEqual(again.stamped + again.copied + again.unstamped, 0)
    }

    func test_perWindowDerivedChild_underADerivedCompound_keepsItsStamp() throws {
        let db = try makeDb()
        let artifactId = BoardSources.derivedTaskId(boardId: "J", rootTaskId: "root")
        try db.saveTask(K.task(artifactId, sharedCounterId: "root", startDate: juneStart, endDate: juneEnd, createdInWizard: true))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try seedCompound(db, childId: artifactId, on: ["J"])

        let r = try heal(db)
        XCTAssertEqual(r.unstamped, 0)
        XCTAssertEqual(try K.fetchTask(db, artifactId)?.startDate, juneStart)
    }

    func test_sealedBoard_reDerivedFromInWindowEventsOnly() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", maxCount: 6, sharedCounterId: "root", currentCount: 7, isCompleted: true))
        try db.saveBoard(K.board(id: "J", startDate: juneStart, endDate: juneEnd))
        try db.saveBoardTask(K.placement(id: "btJ", boardId: "J", taskId: "hub"))
        try K.addIncrement(db, taskId: "root", delta: 2, occurredAt: "2026-06-10T00:00:00.000Z")
        try K.addIncrement(db, taskId: "root", delta: 5, occurredAt: "2026-09-10T00:00:00.000Z")
        XCTAssertTrue(try db.sealBoard(boardId: "J", now: "2026-07-02T00:00:00.000Z"))
        // Sabotage the snapshot to the pre-fix (latch-driven) answer.
        try db.write { try $0.execute(sql: "UPDATE boards SET sealedCompletedCells = '[0]', completedTasks = 1 WHERE id = 'J'") }

        _ = try heal(db)
        let j = try XCTUnwrap(db.fetchBoard(id: "J"))
        XCTAssertEqual(j.completedTasks, 0, "2 in-window miles < 6 — the latch no longer paints it green")
        XCTAssertEqual(j.sealedCompletedCells ?? [], [])
    }

    func test_otherUsersRowsIgnored_andUnplacedRowUntouched() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hubUnplaced", sharedCounterId: "root"))
        let r = try heal(db)
        XCTAssertEqual(r.stamped, 0)
        XCTAssertNil(try K.fetchTask(db, "hubUnplaced")?.startDate)
    }
}
