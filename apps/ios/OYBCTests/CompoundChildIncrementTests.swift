import XCTest
import GRDB
@testable import OYBC

/// `AppDatabase.incrementCompoundChildFallback` — the compound sheet's stepper
/// on a plain COUNTING child not placed on the host board (twin of web
/// `compoundChildIncrement.test.ts`). Board A = June (ended at `lateNow`,
/// unsealed); the child is placed on nothing, the AND-compound parent on A.
@MainActor
final class CompoundChildIncrementTests: XCTestCase {

    private let userId = "u1"
    private let lateNow = "2026-07-02T12:00:00.000Z"

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func task(_ id: String, type: TaskType, maxCount: CountValue? = nil, sharedCounterId: String? = nil) -> Task {
        let now = AppDatabase.currentTimestamp()
        var t = Task(
            id: id, userId: userId, title: id, type: type, action: nil, unit: nil, maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId
        )
        if type == .compound { t.operatorType = .and }
        return t
    }

    private func board(_ id: String, sealedAt: String? = nil) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Board", "status": BoardStatus.active.rawValue,
            "boardSize": 1, "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000", "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 1, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000", "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        return try! JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    /// Parent compound `p` (AND) on board A; counting child `c` (goal 2) placed nowhere.
    private func seed(childLinked: Bool = false, sealed: Bool = false) throws -> (AppDatabase, Board) {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveTask(task("p", type: .compound))
        if childLinked {
            try db.saveTask(task("root", type: .counting, maxCount: nil))
            try db.saveTask(task("c", type: .counting, maxCount: 2, sharedCounterId: "root"))
        } else {
            try db.saveTask(task("c", type: .counting, maxCount: 2))
        }
        let a = board("bA", sealedAt: sealed ? "2026-07-01T06:00:00.000Z" : nil)
        try db.saveBoard(a)
        let now = AppDatabase.currentTimestamp()
        try db.saveBoardTask(BoardTask(
            id: "btA", boardId: "bA", taskId: "p", row: 0, col: 0, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        try db.write { db in
            try CompoundChild(
                id: "p-c", compoundTaskId: "p", childTaskId: "c", childIndex: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            ).save(db)
        }
        return (db, a)
    }

    private func liveEvents(_ db: AppDatabase) throws -> [TaskEvent] {
        try db.read { try TaskEvent.filter(Column("taskId") == "c" && Column("isDeleted") == false).fetchAll($0) }
    }

    private func step(_ db: AppDatabase, _ a: Board, _ delta: CountValue) throws -> [String: AppDatabase.CascadeBoardResult] {
        try db.incrementCompoundChildFallback(
            childTaskId: "c", delta: delta, windowStart: a.startDate, windowEnd: boardWindowEnd(a), boardId: "bA", now: lateNow
        )
    }

    func test_stepsAppendWindowStampedIncrements_andCompleteTheParentAtTheGoal() throws {
        let (db, a) = try seed()
        _ = try step(db, a, 1)
        var events = try liveEvents(db)
        XCTAssertEqual(events.map(\.delta), [1])
        XCTAssertEqual(events[0].boardId, "bA")
        XCTAssertEqual(events[0].occurredAt, boardWindowEnd(a).map { utcStamp($0) }, "stamped at A's endDate (ended, unsealed)")
        XCTAssertEqual(try db.fetchBoard(id: "bA")?.completedTasks, 0, "1 of 2 — parent not yet complete")

        _ = try step(db, a, 1)
        events = try liveEvents(db)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(try db.fetchBoard(id: "bA")?.completedTasks, 1, "child at its goal → the AND parent completes in A's window")

        _ = try step(db, a, -1)
        XCTAssertEqual(try liveEvents(db).reduce(0) { $0 + ($1.delta ?? 0) }, 1)
        XCTAssertEqual(try db.fetchBoard(id: "bA")?.completedTasks, 0, "stepping back un-completes the parent")
    }

    func test_decrementIsGatedAtTheWindowSum_notTheLifetimeSum() throws {
        let (db, a) = try seed()
        XCTAssertTrue(try step(db, a, -1).isEmpty)
        XCTAssertTrue(try liveEvents(db).isEmpty, "nothing to remove → nothing authored")
        // A log in the NEXT window raises the lifetime count, not A's.
        try db.write { db in
            try TaskEvent(
                id: "today", userId: self.userId, taskId: "c", kind: .increment, delta: 3,
                occurredAt: "2026-07-02T08:00:00.000Z", boardId: nil, createdAt: self.lateNow, updatedAt: self.lateNow,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
        XCTAssertTrue(try step(db, a, -1).isEmpty)
        XCTAssertEqual(try liveEvents(db).map(\.id), ["today"])
    }

    func test_linkedChildAndSealedBoardAuthorNothing() throws {
        let (linkedDb, a) = try seed(childLinked: true)
        XCTAssertTrue(try step(linkedDb, a, 1).isEmpty, "a linked child's count is its counter's")
        XCTAssertTrue(try liveEvents(linkedDb).isEmpty)

        let (sealedDb, b) = try seed(sealed: true)
        XCTAssertTrue(try step(sealedDb, b, 1).isEmpty)
        XCTAssertTrue(try liveEvents(sealedDb).isEmpty)
    }

    private func utcStamp(_ localIso: String) -> String {
        ISO8601DateFormatter.string(
            from: parseISO8601Date(localIso)!, timeZone: TimeZone(identifier: "UTC")!,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
    }
}
