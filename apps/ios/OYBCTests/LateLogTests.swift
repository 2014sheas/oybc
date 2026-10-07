import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 4 (T4) — `AppDatabase+LateLog.swift`'s three
/// authoring entry points (D7/D9). Twin of web's `lateLog.test.ts`.
@MainActor
final class LateLogTests: XCTestCase {

    private let userId = "u1"

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeTask(
        _ id: String, type: TaskType = .normal, maxCount: CountValue? = nil,
        sharedCounterId: String? = nil, startDate: String? = nil, endDate: String? = nil,
        createdInWizard: Bool = false, baseline: CountValue? = nil, currentCount: CountValue? = nil,
        isCompleted: Bool = false, operatorType: OperatorType? = nil, threshold: Int? = nil
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: id, description: nil, type: type,
            action: type == .counting ? "Do" : nil, unit: type == .counting ? "reps" : nil,
            maxCount: maxCount, operatorType: operatorType, threshold: threshold,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, completedAt: nil, currentCount: currentCount,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: startDate, endDate: endDate,
            sharedCounterId: sharedCounterId, baseline: baseline, lastSyncedCount: nil,
            createdInWizard: createdInWizard
        )
    }

    private func makeBoard(
        id: String, startDate: String, endDate: String,
        status: BoardStatus = .active, sealedAt: String? = nil, sealedCompletedCells: [Int]? = nil,
        timeframe: Timeframe = .daily, size: Int = 1
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": id, "status": status.rawValue,
            "boardSize": size, "timeframe": timeframe.rawValue,
            "startDate": startDate, "endDate": endDate,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": startDate, "updatedAt": startDate, "version": 1, "isDeleted": false,
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

    private func makeBoardTask(id: String, boardId: String, taskId: String, cell: Int = 0, size: Int = 1) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: cell / size, col: cell % size,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func fetchBoard(_ db: AppDatabase, _ id: String) throws -> Board { try db.fetchBoard(id: id)! }

    private func events(_ db: AppDatabase, taskId: String) throws -> [TaskEvent] {
        try db.read { try TaskEvent.filter(Column("taskId") == taskId).fetchAll($0) }
    }

    // MARK: - R1 scenario: Tue daily closed, Fri late log, weekly+monthly re-derive

    func test_R1_lateLogOnClosedDaily_reDerivesOpenWeeklyAndSealedMonthly() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t-run"))

        // Tuesday's daily — CLOSED.
        let dailyStart = "2026-07-07T00:00:00.000Z"
        let dailyEnd = "2026-07-08T00:00:00.000Z"
        try db.saveBoard(makeBoard(id: "D", startDate: dailyStart, endDate: dailyEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-d", boardId: "D", taskId: "t-run"))

        // The open weekly containing Tuesday.
        try db.saveBoard(makeBoard(id: "W", startDate: "2026-07-06T00:00:00.000Z",
                                    endDate: "2026-07-13T00:00:00.000Z", timeframe: .weekly))
        try db.saveBoardTask(makeBoardTask(id: "bt-w", boardId: "W", taskId: "t-run"))

        // The monthly containing Tuesday — ALREADY sealed too (its own window closed).
        try db.saveBoard(makeBoard(id: "M", startDate: "2026-07-01T00:00:00.000Z",
                                    endDate: "2026-07-31T00:00:00.000Z",
                                    sealedAt: "2026-08-02T00:00:00.000Z", sealedCompletedCells: [],
                                    timeframe: .monthly))
        try db.saveBoardTask(makeBoardTask(id: "bt-m", boardId: "M", taskId: "t-run"))

        // Friday's own daily — must NOT be touched (occurredAt is Tuesday's endDate).
        try db.saveBoard(makeBoard(id: "todayD", startDate: "2026-07-10T00:00:00.000Z", endDate: "2026-07-11T00:00:00.000Z"))
        try db.saveBoardTask(makeBoardTask(id: "bt-today", boardId: "todayD", taskId: "t-run"))

        // Log it Friday.
        try db.lateLogCompletion(boardId: "D", taskId: "t-run", now: "2026-07-10T12:00:00.000Z")

        let ev = try events(db, taskId: "t-run")
        XCTAssertEqual(ev.count, 1)
        XCTAssertEqual(ev[0].occurredAt, dailyEnd, "the late log is stamped at D's endDate, never Friday's now")
        XCTAssertEqual(ev[0].boardId, "D")

        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [0])
        XCTAssertEqual(try fetchBoard(db, "M").sealedCompletedCells, [0], "the sealed monthly containing the stamp must re-derive too")
        XCTAssertEqual(try fetchBoard(db, "W").completedTasks, 1, "the still-open weekly must live-cascade")
        XCTAssertEqual(try fetchBoard(db, "todayD").completedTasks, 0, "Friday's own daily must not count a Tuesday-stamped log")

        // Sealed re-derivation stays local-only — no version bump.
        XCTAssertEqual(try fetchBoard(db, "D").version, 1)
        XCTAssertEqual(try fetchBoard(db, "M").version, 1)
    }

    // MARK: - lateLogCompletion (NORMAL)

    func test_lateLogCompletion_noOpWhenAlreadyCompleteInSealedWindow() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: [0]))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        // Seed a completion already inside the sealed window.
        try db.write {
            try TaskEvent(
                id: "e0", userId: self.userId, taskId: "t1", kind: .completion, delta: nil,
                occurredAt: "2026-07-07T12:00:00.000Z", boardId: nil, createdAt: "2026-07-07T12:00:00.000Z",
                updatedAt: "2026-07-07T12:00:00.000Z", lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save($0)
        }

        try db.lateLogCompletion(boardId: "b1", taskId: "t1", now: "2026-07-10T00:00:00.000Z")

        XCTAssertEqual(try events(db, taskId: "t1").count, 1, "no new event should be authored")
    }

    func test_lateLogCompletion_wrongTaskType_throws() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1", type: .counting, maxCount: 3))
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        XCTAssertThrowsError(try db.lateLogCompletion(boardId: "b1", taskId: "t1")) {
            XCTAssertEqual($0 as? LateLogError, .wrongTaskType)
        }
    }

    func test_lateLogCompletion_taskNotPlaced_throws() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        XCTAssertThrowsError(try db.lateLogCompletion(boardId: "b1", taskId: "t1")) {
            XCTAssertEqual($0 as? LateLogError, .taskNotPlaced)
        }
    }

    func test_lateLogCompletion_unsealedBoard_throws() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        XCTAssertThrowsError(try db.lateLogCompletion(boardId: "b1", taskId: "t1")) {
            XCTAssertEqual($0 as? LateLogError, .boardNotClosed)
        }
    }

    // MARK: - lateLogIncrement (plain COUNTING)

    func test_lateLogIncrement_plainCounting_partialAndOvershootAllowed() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1", type: .counting, maxCount: 5))
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))

        try db.lateLogIncrement(boardId: "b1", taskId: "t1", delta: 2, now: "2026-07-10T00:00:00.000Z")
        XCTAssertEqual(try fetchBoard(db, "b1").sealedCompletedCells, [], "2/5 still not met")

        try db.lateLogIncrement(boardId: "b1", taskId: "t1", delta: 8, now: "2026-07-10T00:00:00.000Z")
        XCTAssertEqual(try fetchBoard(db, "b1").sealedCompletedCells, [0], "overshoot (10/5) still completes")

        let ev = try events(db, taskId: "t1")
        XCTAssertEqual(ev.count, 2)
        XCTAssertTrue(ev.allSatisfy { $0.occurredAt == "2026-07-08T00:00:00.000Z" })
    }

    func test_lateLogIncrement_invalidDelta_throws() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1", type: .counting, maxCount: 5))
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        XCTAssertThrowsError(try db.lateLogIncrement(boardId: "b1", taskId: "t1", delta: 0)) {
            XCTAssertEqual($0 as? LateLogError, .invalidDelta)
        }
    }

    // MARK: - lateLogIncrement (window-stamped derived counter — carve-out)

    func test_lateLogIncrement_windowStampedDerived_appendsOnRoot_propagatesToSiblings() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t-root", type: .counting, maxCount: 100))

        let winStart = "2026-07-07T00:00:00.000Z"
        let winEnd = "2026-07-08T00:00:00.000Z"
        var derived = makeTask("t-derived", type: .counting, maxCount: 5,
                                sharedCounterId: "t-root", startDate: winStart, endDate: winEnd,
                                createdInWizard: true, baseline: 0)
        try db.saveTask(derived)
        try db.saveBoard(makeBoard(id: "b1", startDate: winStart, endDate: winEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t-derived"))

        // A hub-linked sibling of the SAME root, mirroring currentCount.
        let sibling = makeTask("t-sibling", type: .counting, maxCount: 10,
                                sharedCounterId: "t-root", startDate: nil, baseline: 0, currentCount: 0)
        try db.saveTask(sibling)

        try db.lateLogIncrement(boardId: "b1", taskId: "t-derived", delta: 5, now: "2026-07-10T00:00:00.000Z")

        // The event lands on the ROOT, stamped at b1's endDate — the derived
        // row itself owns no events.
        XCTAssertEqual(try events(db, taskId: "t-derived").count, 0)
        let rootEvents = try events(db, taskId: "t-root")
        XCTAssertEqual(rootEvents.count, 1)
        XCTAssertEqual(rootEvents[0].occurredAt, winEnd)
        XCTAssertEqual(try db.fetchTask(id: "t-root")?.currentCount, 5)

        // The sealed board re-derives green from the ROOT's in-window sum.
        XCTAssertEqual(try fetchBoard(db, "b1").sealedCompletedCells, [0])

        // The hub-linked sibling mirrors the root's new lifetime count.
        _ = sibling
        XCTAssertEqual(try db.fetchTask(id: "t-sibling")?.currentCount, 5)
    }

    func test_lateLogIncrement_hubLinkedDerived_isNoOp() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t-root", type: .counting, maxCount: 100, currentCount: 0))
        let hub = makeTask("t-hub", type: .counting, maxCount: 10, sharedCounterId: "t-root", startDate: nil, baseline: 0, currentCount: 0)
        try db.saveTask(hub)
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t-hub"))

        try db.lateLogIncrement(boardId: "b1", taskId: "t-hub", delta: 5, now: "2026-07-10T00:00:00.000Z")

        XCTAssertEqual(try events(db, taskId: "t-root").count, 0, "a hub-linked derived square is not tappable on a closed board (OQ2)")
        XCTAssertEqual(try db.fetchTask(id: "t-root")?.currentCount, 0)
    }

    // MARK: - lateLogCompoundParts (COMPOUND)

    private func makeCompound(_ id: String, operatorType: OperatorType) -> Task {
        makeTask(id, type: .compound, operatorType: operatorType)
    }

    private func link(_ id: String, compound: String, child: String, index: Int) -> CompoundChild {
        let now = AppDatabase.currentTimestamp()
        return CompoundChild(
            id: id, compoundTaskId: compound, childTaskId: child, childIndex: index,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    func test_lateLogCompoundParts_andRule_rejectsUntilAllStaged() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeCompound("c1", operatorType: .and))
        try db.saveTask(makeTask("child1"))
        try db.saveTask(makeTask("child2"))
        try db.write {
            try self.link("l1", compound: "c1", child: "child1", index: 0).save($0)
            try self.link("l2", compound: "c1", child: "child2", index: 1).save($0)
        }
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "c1"))

        XCTAssertThrowsError(try db.lateLogCompoundParts(boardId: "b1", compoundTaskId: "c1", childTaskIds: ["child1"])) {
            XCTAssertEqual($0 as? LateLogError, .ruleNotMet)
        }
        XCTAssertEqual(try events(db, taskId: "child1").count, 0, "a rejected commit must write nothing")

        try db.lateLogCompoundParts(boardId: "b1", compoundTaskId: "c1", childTaskIds: ["child1", "child2"])
        XCTAssertEqual(try events(db, taskId: "child1").count, 1)
        XCTAssertEqual(try events(db, taskId: "child2").count, 1)
        XCTAssertEqual(try fetchBoard(db, "b1").sealedCompletedCells, [0])
    }

    func test_lateLogCompoundParts_orRule_oneChildIsEnough() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeCompound("c1", operatorType: .or))
        try db.saveTask(makeTask("child1"))
        try db.saveTask(makeTask("child2"))
        try db.write {
            try self.link("l1", compound: "c1", child: "child1", index: 0).save($0)
            try self.link("l2", compound: "c1", child: "child2", index: 1).save($0)
        }
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "c1"))

        try db.lateLogCompoundParts(boardId: "b1", compoundTaskId: "c1", childTaskIds: ["child1"])
        XCTAssertEqual(try fetchBoard(db, "b1").sealedCompletedCells, [0])
        XCTAssertEqual(try events(db, taskId: "child2").count, 0, "the un-staged OR sibling must not be touched")
    }
}
