import XCTest
import GRDB
@testable import OYBC

/// Board Edit post-merge sweep (finding 2) — the closed-board late-log writes
/// on `BoardPlayViewModel` carry an in-flight guard: a second call made while
/// one is still running is a no-op, so a rapid double-tap on the sheet can
/// never author two late logs / pop two undos. (The web `LateLogSheet`
/// disables every action while `busy`; the iOS sheet mirrors that AND the VM
/// refuses re-entry, so the guarantee doesn't depend on UI timing.)
@MainActor
final class LateLogInFlightGuardTests: XCTestCase {

    private let userId = "u1"
    private let start = "2026-07-01T00:00:00.000Z"
    private let end = "2026-07-01T23:59:59.999Z"
    private let pastAutoClose = "2026-07-03T01:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        return db
    }

    private func makeTask(_ id: String, type: TaskType) -> Task {
        Task(
            id: id, userId: userId, title: id, description: nil, type: type,
            action: type == .counting ? "Do" : nil, unit: nil, maxCount: type == .counting ? 10 : nil,
            operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: type == .counting ? 0 : nil,
            createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        )
    }

    /// A CLOSED 1×1 board "B" placing `task`.
    private func seedClosedBoard(_ db: AppDatabase, task: Task) throws {
        try db.saveTask(task)
        let dict: [String: Any] = [
            "id": "B", "userId": userId, "name": "B", "status": "active",
            "boardSize": 1, "timeframe": Timeframe.daily.rawValue,
            "startDate": start, "endDate": end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 1, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false,
        ]
        try db.saveBoard(try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict)))
        try db.saveBoardTask(BoardTask(
            id: "bt", boardId: "B", taskId: task.id, row: 0, col: 0,
            isCenter: false, createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1
        ))
        try db.closeBoard(boardId: "B", now: pastAutoClose)
    }

    private func liveEvents(_ db: AppDatabase, taskId: String) throws -> [TaskEvent] {
        try db.read { try TaskEvent.filter(Column("taskId") == taskId && Column("isDeleted") == false).fetchAll($0) }
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    /// Fires `operation` twice back-to-back (a double-tap: the second call
    /// starts while the first is still suspended on its DB write) and waits
    /// for both to finish.
    private func doubleTap(_ operation: @escaping () async throws -> Void) {
        var finished = 0
        for _ in 0..<2 {
            _Concurrency.Task { @MainActor in
                try? await operation()
                finished += 1
            }
        }
        XCTAssertTrue(waitUntil { finished == 2 }, "both calls must complete")
    }

    private func loadedVM(_ db: AppDatabase, taskId: String) -> BoardPlayViewModel {
        let vm = BoardPlayViewModel(boardId: "B", userId: userId, database: db)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "B" && vm.taskMap[taskId] != nil })
        return vm
    }

    func test_doubleTapLogAmount_authorsOneLateLog() throws {
        let db = try makeDb()
        let counter = makeTask("C", type: .counting)
        try seedClosedBoard(db, task: counter)
        let vm = loadedVM(db, taskId: "C")

        doubleTap { try await vm.commitLateLogIncrement(for: counter, delta: 1) }

        XCTAssertEqual(try liveEvents(db, taskId: "C").count, 1, "a double-tap must author exactly one late log")
        XCTAssertFalse(vm.isLateLogInFlight, "the guard clears once the write finishes")
    }

    func test_doubleTapUndo_popsOneLateLog() throws {
        let db = try makeDb()
        let counter = makeTask("C", type: .counting)
        try seedClosedBoard(db, task: counter)
        try db.lateLogIncrement(boardId: "B", taskId: "C", delta: 1, now: "2026-07-04T00:00:00.000Z")
        try db.lateLogIncrement(boardId: "B", taskId: "C", delta: 1, now: "2026-07-04T00:01:00.000Z")
        let vm = loadedVM(db, taskId: "C")

        doubleTap { try await vm.undoLateLog(for: counter) }

        XCTAssertEqual(try liveEvents(db, taskId: "C").count, 1, "a double-tap Undo must pop exactly one late log")
    }

    func test_doubleTapMarkDone_normal_authorsOneEvent() throws {
        let db = try makeDb()
        let normal = makeTask("N", type: .normal)
        try seedClosedBoard(db, task: normal)
        let vm = loadedVM(db, taskId: "N")

        doubleTap { try await vm.commitLateLogCompletion(taskId: "N") }

        XCTAssertEqual(try liveEvents(db, taskId: "N").count, 1)
    }
}
