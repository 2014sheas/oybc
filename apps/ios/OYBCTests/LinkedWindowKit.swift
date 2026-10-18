import XCTest
import GRDB
@testable import OYBC

/// Shared seed helpers for the windowed-linked-counters suites (owner rule
/// 2026-10-01: a counting square accounts only for logs inside its board's
/// window). Plain fixtures — no assertions. (Survivor of the retired heal suite, slice 3a.)
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
