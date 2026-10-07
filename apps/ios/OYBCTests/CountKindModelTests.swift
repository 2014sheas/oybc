import XCTest
import GRDB
@testable import OYBC

final class CountKindModelTests: XCTestCase {
    /// `tasks.userId` is a foreign key to `users`, so every test seeds "u1" first.
    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: "u1", email: "test@example.com", displayName: "Test User", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        return db
    }

    /// Copy of `AppDatabaseCounterLogOpsTests.makeSourceTask` (it is private there),
    /// with its count params retyped to `CountValue` and `countKind: nil` appended.
    private func countingTask(id: String = UUID().uuidString) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: "u1", title: "Test Counter \(id)", description: nil, type: .counting,
            action: "Run", unit: "miles", maxCount: 20, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0, isCompleted: false, completedAt: nil, currentCount: 0,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil, sharedCounterId: nil, baseline: nil,
            lastSyncedCount: nil, createdInWizard: false, isCounter: false, defaultLogAmount: nil,
            countKind: nil
        )
    }

    func testContinuousTaskRoundTripsThroughGRDB() throws {
        let db = try makeDb()
        var t = countingTask()
        t.countKind = .continuous
        t.maxCount = 26.2
        t.currentCount = 3.1
        t.defaultLogAmount = 3.1
        try db.write { try t.save($0) }
        let back = try db.read { try Task.fetchOne($0, key: t.id) }!
        XCTAssertEqual(back.countKind, .continuous)
        XCTAssertEqual(back.maxCount, 26.2)
        XCTAssertEqual(back.currentCount, 3.1)
    }

    func testPreFeatureRowDecodesAsDiscrete() throws {
        let db = try makeDb()
        let t = countingTask()
        try db.write { try t.save($0) }
        try db.write { try $0.execute(sql: "UPDATE tasks SET countKind = NULL WHERE id = ?", arguments: [t.id]) }
        let back = try db.read { try Task.fetchOne($0, key: t.id) }!
        XCTAssertNil(back.countKind)
        XCTAssertEqual(resolveCountKind(back.countKind), .discrete)
    }

    func testIntegerColumnStoresFractionalDelta() throws {
        // INTEGER affinity keeps 3.1 as REAL; decoding into CountValue? must succeed.
        let db = try makeDb()
        let t = countingTask()
        try db.write { try t.save($0) }
        try db.write {
            try $0.execute(sql: "UPDATE tasks SET maxCount = 26.2, currentCount = 3.1 WHERE id = ?", arguments: [t.id])
        }
        let back = try db.read { try Task.fetchOne($0, key: t.id) }!
        XCTAssertEqual(back.maxCount, 26.2)
        XCTAssertEqual(back.currentCount, 3.1)
    }

    func testPulledFirestoreDoubleDecodes() throws {
        // A Firestore number arrives as NSNumber(26.2). SyncService's raw upsert
        // skips the `as? Int` branch (Swift refuses a lossy NSNumber→Int bridge)
        // and binds it as a Double; the decode below is the same Codable path
        // `SyncService.applyPulledDocument` ends in (SyncWirePayloadTests precedent).
        var row = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(countingTask())) as! [String: Any]
        row["maxCount"] = NSNumber(value: 26.2)
        row["currentCount"] = NSNumber(value: 3.1)
        row["countKind"] = "continuous"
        let pulled = try JSONDecoder().decode(Task.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertEqual(pulled.maxCount, 26.2)
        XCTAssertEqual(pulled.currentCount, 3.1)
        XCTAssertEqual(pulled.countKind, .continuous)
        XCTAssertNil(NSNumber(value: 3.1) as? Int, "the upsert's Int branch must not swallow a fractional value")
    }
}
