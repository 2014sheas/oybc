import XCTest
import GRDB
@testable import OYBC

/// Windowed Completion PR C slice 2 — sealed-window tombstone immunity
/// (docs/WINDOWED_COMPLETION.md §Write paths → "Sealed-window immunity" /
/// Decision 9). Twin of web's `tombstoneSealImmunity.test.ts`.
///
/// An event whose `occurredAt` falls inside `[startDate, min(endDate,
/// sealedAt)]` of a sealed board that places the task can NEVER be tombstoned — history stays
/// history. The library un-complete affordance reads
/// `isUncompleteBlockedBySeal` to disable-with-explanation when a task is
/// green only via such an event.
@MainActor
final class TombstoneSealImmunityTests: XCTestCase {

    private let userId = "u1"
    private let start = "2026-07-01T00:00:00.000Z"
    private let end = "2026-07-02T00:00:00.000Z"
    private let sealedAt = "2026-07-02T06:00:00.000Z"
    private let inSealedWindow = "2026-07-01T12:00:00.000Z" // inside [start, sealedAt]
    private let postSeal = "2026-07-02T12:00:00.000Z" // after sealedAt → tombstonable overtime
    private let overtimeGap = "2026-07-02T01:00:00.000Z" // end < t <= sealedAt → next window's, not immune (F1)

    private let taskA = "10000000-0000-4000-8000-000000000001"
    private let sealedBoardId = "20000000-0000-4000-8000-000000000001"
    private let liveBoardId = "20000000-0000-4000-8000-000000000002"

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func seedNormalTask(_ db: AppDatabase, isCompleted: Bool = true) throws {
        try db.saveTask(Task(
            id: taskA, userId: userId, title: "N", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: isCompleted ? 1 : 0, totalInstances: 1,
            isCompleted: isCompleted, completedAt: isCompleted ? inSealedWindow : nil,
            currentCount: nil, createdAt: start, updatedAt: start,
            lastSyncedAt: nil, version: 3, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        ))
    }

    private func makeBoard(id: String, sealedAt: String? = nil, startDate: String? = nil, endDate: String? = nil) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "B", "status": "active",
            "boardSize": 3, "timeframe": "daily",
            "startDate": startDate ?? start, "endDate": endDate ?? end,
            "centerSquareType": "none", "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func placeTask(_ db: AppDatabase, boardId: String, cell: Int = 0) throws {
        try db.saveBoardTask(BoardTask(
            id: "bt-\(boardId)-\(taskA)", boardId: boardId, taskId: taskA,
            row: cell / 3, col: cell % 3, isCenter: false,
            createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1
        ))
    }

    private func completionEvent(_ id: String, occurredAt: String) -> TaskEvent {
        TaskEvent(
            id: id, userId: userId, taskId: taskA, kind: .completion, delta: nil,
            occurredAt: occurredAt, boardId: nil, createdAt: occurredAt, updatedAt: occurredAt,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    // MARK: - F1: immune window = [startDate, min(endDate, sealedAt)]

    /// An event in the overtime gap (endDate < t <= sealedAt) never counted on
    /// the sealed board — it belongs to the NEXT window — so un-completing it
    /// on the next board must tombstone it.
    func test_F1_overtimeGapEventIsNotImmune() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: sealedBoardId, sealedAt: sealedAt))
        try placeTask(db, boardId: sealedBoardId)
        try db.saveBoard(makeBoard(id: liveBoardId, startDate: end, endDate: "2026-07-02T23:59:59.999Z"))
        try placeTask(db, boardId: liveBoardId)
        try db.write { try self.completionEvent("e-gap", occurredAt: self.overtimeGap).save($0) }

        try db.write { try AppDatabase.tombstoneWindowCompletions(db: $0, taskId: self.taskA, windowStart: self.end, now: "2026-07-02T08:00:00.000Z", windowEnd: "2026-07-02T23:59:59.999Z") }

        let ev = try db.read { try TaskEvent.fetchOne($0, key: "e-gap") }
        XCTAssertEqual(ev?.isDeleted, true)
    }

    /// An event exactly at endDate stays immune (inclusive upper bound).
    func test_F1_eventAtEndDateStaysImmune() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: sealedBoardId, sealedAt: sealedAt))
        try placeTask(db, boardId: sealedBoardId)
        try db.write { try self.completionEvent("e-end", occurredAt: self.end).save($0) }

        try db.write { try AppDatabase.tombstoneWindowCompletions(db: $0, taskId: self.taskA, windowStart: self.start, now: "2026-07-03T00:00:00.000Z", windowEnd: nil) }

        let ev = try db.read { try TaskEvent.fetchOne($0, key: "e-end") }
        XCTAssertEqual(ev?.isDeleted, false)
    }

    /// Pure helper: the bound clamps to endDate; nil/unparseable endDate = sealedAt.
    func test_F1_buildSealImmuneWindowsClampsToEndDate() {
        let w = buildSealImmuneWindows(sealedBoards: [
            (startDate: start, endDate: end, sealedAt: sealedAt),
            (startDate: start, endDate: nil, sealedAt: sealedAt),
            (startDate: start, endDate: "not-a-date", sealedAt: sealedAt),
        ])
        let endMs = DateFormatting.parseISO(end)!.timeIntervalSince1970 * 1000
        let sealedMs = DateFormatting.parseISO(sealedAt)!.timeIntervalSince1970 * 1000
        XCTAssertEqual(w.map(\.endMs), [endMs, sealedMs, sealedMs])
        XCTAssertFalse(isOccurredAtSealImmune(overtimeGap, windows: [w[0]]))
        XCTAssertTrue(isOccurredAtSealImmune(end, windows: [w[0]]))
    }

    // MARK: - F11: unparseable windowEnd fails open (web parity)

    func test_F11_unparseableWindowEnd_failsOpen_tombstonesFromStartOn() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: liveBoardId))
        try placeTask(db, boardId: liveBoardId)
        try db.write { db in
            try self.completionEvent("e-in", occurredAt: self.inSealedWindow).save(db)
            try self.completionEvent("e-later", occurredAt: self.postSeal).save(db)
        }

        try db.write { try AppDatabase.tombstoneWindowCompletions(db: $0, taskId: self.taskA, windowStart: self.start, now: "2026-07-03T00:00:00.000Z", windowEnd: "not-a-date") }

        let evs = try db.read { try TaskEvent.fetchAll($0) }
        XCTAssertEqual(evs.filter(\.isDeleted).map(\.id).sorted(), ["e-in", "e-later"])
    }

    // MARK: - tombstoneWindowCompletions — sealed-window immunity

    func test_tombstoneWindowCompletions_doesNotTombstoneImmuneEvent() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: sealedBoardId, sealedAt: sealedAt))
        try placeTask(db, boardId: sealedBoardId)
        try db.write { try self.completionEvent("e-immune", occurredAt: self.inSealedWindow).save($0) }

        try db.write { try AppDatabase.tombstoneWindowCompletions(db: $0, taskId: self.taskA, windowStart: self.start, now: "2026-07-03T00:00:00.000Z", windowEnd: nil) }

        let ev = try db.read { try TaskEvent.fetchOne($0, key: "e-immune") }
        XCTAssertEqual(ev?.isDeleted, false) // immune — history stays
        let task = try db.fetchTask(id: taskA)
        XCTAssertEqual(task?.isCompleted, true) // the immune event keeps the lifetime cache green
    }

    func test_tombstoneWindowCompletions_tombstonesNonImmuneSparesImmune() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: sealedBoardId, sealedAt: sealedAt))
        try placeTask(db, boardId: sealedBoardId)
        try db.write { db in
            try self.completionEvent("e-immune", occurredAt: self.inSealedWindow).save(db)
            try self.completionEvent("e-open", occurredAt: self.postSeal).save(db)
        }

        try db.write { try AppDatabase.tombstoneWindowCompletions(db: $0, taskId: self.taskA, windowStart: self.start, now: "2026-07-03T00:00:00.000Z", windowEnd: nil) }

        XCTAssertEqual(try db.read { try TaskEvent.fetchOne($0, key: "e-immune") }?.isDeleted, false)
        XCTAssertEqual(try db.read { try TaskEvent.fetchOne($0, key: "e-open") }?.isDeleted, true)
    }

    func test_tombstoneWindowCompletions_tombstonesNormallyWithNoSealedBoard() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: liveBoardId)) // not sealed
        try placeTask(db, boardId: liveBoardId)
        try db.write { try self.completionEvent("e1", occurredAt: self.inSealedWindow).save($0) }

        try db.write { try AppDatabase.tombstoneWindowCompletions(db: $0, taskId: self.taskA, windowStart: self.start, now: "2026-07-03T00:00:00.000Z", windowEnd: nil) }

        XCTAssertEqual(try db.read { try TaskEvent.fetchOne($0, key: "e1") }?.isDeleted, true)
        XCTAssertEqual(try db.fetchTask(id: taskA)?.isCompleted, false)
    }

    // MARK: - tombstoneLatestCompletion — sealed-window immunity

    func test_tombstoneLatestCompletion_picksLatestNonImmuneLeavesImmuneIntact() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: sealedBoardId, sealedAt: sealedAt))
        try placeTask(db, boardId: sealedBoardId)
        try db.write { db in
            try self.completionEvent("e-immune", occurredAt: self.inSealedWindow).save(db)
            try self.completionEvent("e-open", occurredAt: self.postSeal).save(db)
        }

        try db.write { try AppDatabase.tombstoneLatestCompletion(db: $0, taskId: self.taskA, now: "2026-07-03T00:00:00.000Z") }

        XCTAssertEqual(try db.read { try TaskEvent.fetchOne($0, key: "e-immune") }?.isDeleted, false)
        XCTAssertEqual(try db.read { try TaskEvent.fetchOne($0, key: "e-open") }?.isDeleted, true)
    }

    func test_tombstoneLatestCompletion_isInertWhenOnlyLiveCompletionIsImmune() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: sealedBoardId, sealedAt: sealedAt))
        try placeTask(db, boardId: sealedBoardId)
        try db.write { try self.completionEvent("e-immune", occurredAt: self.inSealedWindow).save($0) }

        try db.write { try AppDatabase.tombstoneLatestCompletion(db: $0, taskId: self.taskA, now: "2026-07-03T00:00:00.000Z") }

        XCTAssertEqual(try db.read { try TaskEvent.fetchOne($0, key: "e-immune") }?.isDeleted, false)
        // Cache recomputes from the (still-live) immune event → stays complete.
        XCTAssertEqual(try db.fetchTask(id: taskA)?.isCompleted, true)
    }

    // MARK: - isUncompleteBlockedBySeal

    func test_isUncompleteBlockedBySeal_trueWhenGreenOnlyViaImmuneCompletion() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: sealedBoardId, sealedAt: sealedAt))
        try placeTask(db, boardId: sealedBoardId)
        try db.write { try self.completionEvent("e-immune", occurredAt: self.inSealedWindow).save($0) }

        XCTAssertTrue(try db.isUncompleteBlockedBySeal(taskId: taskA))
    }

    func test_isUncompleteBlockedBySeal_falseWhenNonImmuneCompletionAlsoExists() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: sealedBoardId, sealedAt: sealedAt))
        try placeTask(db, boardId: sealedBoardId)
        try db.write { db in
            try self.completionEvent("e-immune", occurredAt: self.inSealedWindow).save(db)
            try self.completionEvent("e-open", occurredAt: self.postSeal).save(db)
        }

        XCTAssertFalse(try db.isUncompleteBlockedBySeal(taskId: taskA))
    }

    func test_isUncompleteBlockedBySeal_falseWithNoSealedBoardsAtAll() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db)
        try db.saveBoard(makeBoard(id: liveBoardId))
        try placeTask(db, boardId: liveBoardId)
        try db.write { try self.completionEvent("e1", occurredAt: self.inSealedWindow).save($0) }

        XCTAssertFalse(try db.isUncompleteBlockedBySeal(taskId: taskA))
    }

    func test_isUncompleteBlockedBySeal_falseWithNoLiveCompletionsAtAll() throws {
        let db = try makeDb(); try seedUser(db)
        try seedNormalTask(db, isCompleted: false)
        try db.saveBoard(makeBoard(id: sealedBoardId, sealedAt: sealedAt))
        try placeTask(db, boardId: sealedBoardId)

        XCTAssertFalse(try db.isUncompleteBlockedBySeal(taskId: taskA))
    }
}
