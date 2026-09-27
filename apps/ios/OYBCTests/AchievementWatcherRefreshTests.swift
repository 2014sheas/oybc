import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 4 (D8) — `AppDatabase.refreshWatchersForBoards`,
/// exercised via its two remaining callers not already covered by
/// `BoardLifecycleTests` (Close/Reopen): a closed-board late log, and
/// template-mode watchers (`referencedTemplateId`). Twin of web's
/// `achievementWatcherRefresh.test.ts`.
@MainActor
final class AchievementWatcherRefreshTests: XCTestCase {

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

    private func makeTask(_ id: String) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: id, description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        )
    }

    private func makeWatcherTask(
        _ id: String, referencedBoardId: String? = nil, referencedTemplateId: String? = nil
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: id, description: nil, type: .achievement,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: referencedBoardId, referencedTemplateId: referencedTemplateId,
            achievementTrigger: .greenlog, requiredCount: referencedTemplateId != nil ? 1 : nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        )
    }

    private func makeBoard(
        id: String, startDate: String, endDate: String,
        status: BoardStatus = .active, sealedAt: String? = nil, sealedCompletedCells: [Int]? = nil,
        spawnedFromTemplateId: String? = nil, size: Int = 1
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": id, "status": status.rawValue,
            "boardSize": size, "timeframe": Timeframe.daily.rawValue,
            "startDate": startDate, "endDate": endDate,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": startDate, "updatedAt": startDate, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        if let spawnedFromTemplateId { dict["spawnedFromTemplateId"] = spawnedFromTemplateId }
        if let cells = sealedCompletedCells,
           let data = try? JSONEncoder().encode(cells),
           let str = String(data: data, encoding: .utf8) {
            dict["sealedCompletedCells"] = str
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: 0, col: 0,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func fetchBoard(_ db: AppDatabase, _ id: String) throws -> Board { try db.fetchBoard(id: id)! }

    /// A closed-board late log that greenlogs the watched board must refresh
    /// a specific-board watcher on another board.
    func test_lateLog_refreshesSpecificBoardWatcher() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "watched", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "watched", taskId: "t1"))

        try db.saveTask(makeWatcherTask("w1", referencedBoardId: "watched"))
        try db.saveBoard(makeBoard(id: "hostBoard", startDate: "2026-07-10T00:00:00.000Z", endDate: "2026-07-11T00:00:00.000Z"))
        try db.saveBoardTask(makeBoardTask(id: "bt-w", boardId: "hostBoard", taskId: "w1"))

        try db.lateLogCompletion(boardId: "watched", taskId: "t1", now: "2026-07-12T00:00:00.000Z")

        XCTAssertEqual(try fetchBoard(db, "watched").sealedCompletedCells, [0])
        XCTAssertEqual(try fetchBoard(db, "hostBoard").completedTasks, 1, "the specific-board watcher must repaint")
    }

    /// A template-mode watcher (`referencedTemplateId`) matches ANY board
    /// spawned from that template — including the one just closed.
    func test_lateLog_refreshesTemplateModeWatcher() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "watched", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: [],
                                    spawnedFromTemplateId: "tmpl1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "watched", taskId: "t1"))

        try db.saveTask(makeWatcherTask("w1", referencedTemplateId: "tmpl1"))
        // Template-mode matches spawns whose startDate falls within the HOST
        // board's own window — must encompass `watched`'s 07-07 startDate.
        try db.saveBoard(makeBoard(id: "hostBoard", startDate: "2026-07-01T00:00:00.000Z", endDate: "2026-07-31T00:00:00.000Z"))
        try db.saveBoardTask(makeBoardTask(id: "bt-w", boardId: "hostBoard", taskId: "w1"))

        try db.lateLogCompletion(boardId: "watched", taskId: "t1", now: "2026-08-01T00:00:00.000Z")

        XCTAssertEqual(try fetchBoard(db, "hostBoard").completedTasks, 1, "the template-mode watcher must repaint too")
    }

    /// A non-achievement task placing the watched board's task must never be
    /// swept up by the refresh (sanity: it only acts on ACHIEVEMENT rows).
    func test_refreshWatchers_ignoresNonAchievementAndDeletedWatchers() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "watched", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "watched", taskId: "t1"))

        var deletedWatcher = makeWatcherTask("w-dead", referencedBoardId: "watched")
        deletedWatcher.isDeleted = true
        try db.saveTask(deletedWatcher)
        try db.saveBoard(makeBoard(id: "hostBoard", startDate: "2026-07-10T00:00:00.000Z", endDate: "2026-07-11T00:00:00.000Z"))
        try db.saveBoardTask(makeBoardTask(id: "bt-w", boardId: "hostBoard", taskId: "w-dead"))

        try db.lateLogCompletion(boardId: "watched", taskId: "t1", now: "2026-07-12T00:00:00.000Z")

        XCTAssertEqual(try fetchBoard(db, "hostBoard").completedTasks, 0, "a deleted watcher must never be refreshed")
    }
}
