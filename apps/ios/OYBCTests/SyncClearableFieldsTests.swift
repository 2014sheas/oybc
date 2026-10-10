import XCTest
import GRDB
import FirebaseFirestore
@testable import OYBC

/// Board Edit redesign slice 4 (D2) — `SyncService+ClearableFields.swift`.
/// A Reopen clears `sealedAt` / `sealedCompletedCells` locally; these tests
/// pin that the push side stamps `FieldValue.delete()` for every absent
/// clearable field, and the pull side NULLs the local column when a winning
/// remote doc omits it — the same carve-out `endDate` / `completedAt` already
/// had, now centralized and extended to all four fields. Since 2026-09-29 the
/// mechanism is per-collection: `coreBoardDefaults` clears its per-timeframe
/// size / centre overrides the same way (see the last section).
@MainActor
final class SyncClearableFieldsTests: XCTestCase {

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: "u1", email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    // MARK: - Push: FieldValue.delete() for every absent clearable field

    func test_applyClearableBoardFieldDeletes_stampsDeleteForEveryAbsentField() {
        var cleaned: [String: Any] = ["id": "b1", "name": "Board"] // sealedAt etc. all absent
        SyncService.applyClearableFieldDeletes(collection: "boards", cleaned: &cleaned)

        for field in clearableBoardFields {
            XCTAssertTrue(cleaned[field] is FieldValue, "\(field) must be stamped FieldValue.delete() when absent")
        }
        XCTAssertEqual(cleaned["name"] as? String, "Board", "present fields are untouched")
    }

    func test_applyClearableBoardFieldDeletes_leavesPresentFieldsAlone() {
        var cleaned: [String: Any] = ["id": "b1", "sealedAt": "2026-07-09T00:00:00.000Z"]
        SyncService.applyClearableFieldDeletes(collection: "boards", cleaned: &cleaned)

        XCTAssertEqual(cleaned["sealedAt"] as? String, "2026-07-09T00:00:00.000Z", "a PRESENT clearable field must not be deleted")
        XCTAssertTrue(cleaned["endDate"] is FieldValue, "an absent one still gets the delete stamp")
    }

    func test_applyClearableBoardFieldDeletes_noOpForNonBoardsCollection() {
        var cleaned: [String: Any] = ["id": "t1"]
        SyncService.applyClearableFieldDeletes(collection: "boardTasks", cleaned: &cleaned)
        for field in clearableBoardFields {
            XCTAssertNil(cleaned[field], "non-boards collections must never get the boards-only carve-out")
        }
    }

    // MARK: - Pull: NULL every clearable field absent from a winning remote doc

    private func makeSealedBoard(id: String) -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": "u1", "name": "B", "status": BoardStatus.active.rawValue,
            "boardSize": 1, "timeframe": Timeframe.daily.rawValue,
            "startDate": "2026-07-01T00:00:00.000Z", "endDate": "2026-07-02T00:00:00.000Z",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 1, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-07-01T00:00:00.000Z", "updatedAt": "2026-07-01T00:00:00.000Z",
            "completedAt": "2026-07-05T00:00:00.000Z",
            "version": 1, "isDeleted": false,
            "sealedAt": "2026-07-09T00:00:00.000Z", "sealedCompletedCells": "[0]",
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    func test_applyClearableBoardFieldNulls_clearsAbsentFieldsOnLocalRow() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(makeSealedBoard(id: "b1"))

        // A winning remote doc that omits ALL four clearable fields (mirrors
        // a Reopen's push, which deletes them) — every one must NULL locally.
        try db.write { conn in
            try SyncService.applyClearableFieldNulls(db: conn, grdbTable: "boards", cleaned: ["id": "b1"])
        }

        let board = try db.fetchBoard(id: "b1")!
        XCTAssertNil(board.endDate)
        XCTAssertNil(board.completedAt)
        XCTAssertNil(board.sealedAt)
        XCTAssertNil(board.sealedCompletedCells)
    }

    func test_applyClearableBoardFieldNulls_leavesPresentFieldsAlone() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(makeSealedBoard(id: "b1"))

        // The remote doc carries a present sealedAt (a re-close after a
        // reopen) — this must survive, not be NULLed.
        try db.write { conn in
            try SyncService.applyClearableFieldNulls(
                db: conn, grdbTable: "boards", cleaned: ["id": "b1", "sealedAt": "2026-07-20T00:00:00.000Z"]
            )
        }

        XCTAssertEqual(try db.fetchBoard(id: "b1")?.sealedAt, "2026-07-09T00:00:00.000Z", "raw SQL NULL-out only touches ABSENT fields")
    }

    func test_applyClearableBoardFieldNulls_noOpForNonBoardsTable() throws {
        let db = try AppDatabase.makeTestInstance()
        // Should not throw / touch anything for a table with no clearable fields.
        try db.write { conn in
            try SyncService.applyClearableFieldNulls(db: conn, grdbTable: "board_tasks", cleaned: ["id": "t1"])
        }
    }

    // MARK: - tasks.endDate (windowed-linked-counter heal stamp onto an indefinite board)

    func test_applyClearableFieldDeletes_tasks_stampsEndDateDeleteWhenAbsent() {
        var cleaned: [String: Any] = ["id": "t1", "title": "Run"]
        SyncService.applyClearableFieldDeletes(collection: "tasks", cleaned: &cleaned)
        XCTAssertTrue(cleaned["endDate"] is FieldValue, "a nil task endDate must push a delete")
        var present: [String: Any] = ["id": "t1", "endDate": "2026-09-30T00:00:00.000Z"]
        SyncService.applyClearableFieldDeletes(collection: "tasks", cleaned: &present)
        XCTAssertEqual(present["endDate"] as? String, "2026-09-30T00:00:00.000Z")
    }

    func test_applyClearableFieldNulls_tasks_clearsEndDateWhenAbsentFromRemote() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveTask(LinkedWindowKit.task(
            "t1", startDate: "2026-09-01T00:00:00.000Z", endDate: "2026-09-30T00:00:00.000Z"
        ))
        try db.write { conn in
            try SyncService.applyClearableFieldNulls(db: conn, grdbTable: "tasks", cleaned: ["id": "t1"])
        }
        let end = try db.read { try String.fetchOne($0, sql: "SELECT endDate FROM tasks WHERE id = 't1'") }
        XCTAssertNil(end)
    }

    // MARK: - coreBoardDefaults: per-timeframe size / centre overrides (2026-09-29)

    func test_clearableFieldsFor_perCollectionMap() {
        // Literal names, not `clearableBoardFields` — that constant IS this map's
        // `boards` entry, so comparing the two would assert nothing.
        XCTAssertEqual(Set(SyncService.clearableFields(for: "boards")), ["endDate", "completedAt", "sealedAt", "sealedCompletedCells"])
        XCTAssertEqual(Set(SyncService.clearableFields(for: "coreBoardDefaults")), ["defaultBoardSize", "defaultCenterType"])
        XCTAssertEqual(
            SyncService.clearableFields(for: "tasks"),
            [
                "endDate", "counterName", "titleTemplateSingular", "titleTemplatePlural", "timeframeGoals",
                "countsTowardCounterId", "countsTowardAmount", "countsTowardSince",
            ]
        )
        // A revived counts-toward credit drops its tombstone stamp (SHARED_COUNTER_SETTINGS §3b).
        XCTAssertEqual(SyncService.clearableFields(for: "taskEvents"), ["deletedAt"])
        XCTAssertEqual(SyncService.clearableFields(for: "boardTasks"), [])
        XCTAssertEqual(SyncService.clearableFields(for: "nope"), [])
    }

    func test_applyClearableFieldDeletes_coreBoardDefaults_stampsBothWhenAbsent() {
        var cleaned: [String: Any] = ["id": "cbd-1", "corePoolIds": ["p1"]]
        SyncService.applyClearableFieldDeletes(collection: "coreBoardDefaults", cleaned: &cleaned)
        XCTAssertTrue(cleaned["defaultBoardSize"] is FieldValue)
        XCTAssertTrue(cleaned["defaultCenterType"] is FieldValue)
        XCTAssertEqual(cleaned["corePoolIds"] as? [String], ["p1"], "present fields are untouched")
        for field in clearableBoardFields {
            XCTAssertNil(cleaned[field], "boards-only field \(field) must never leak onto a coreBoardDefaults doc")
        }
    }

    func test_applyClearableFieldDeletes_coreBoardDefaults_leavesPresentAlone() {
        var cleaned: [String: Any] = ["id": "cbd-1", "defaultBoardSize": 4]
        SyncService.applyClearableFieldDeletes(collection: "coreBoardDefaults", cleaned: &cleaned)
        XCTAssertEqual(cleaned["defaultBoardSize"] as? Int, 4)
        XCTAssertTrue(cleaned["defaultCenterType"] is FieldValue)
    }

    private func seedCoreDefault(_ db: AppDatabase, size: DefaultBoardSize?, centre: DefaultCenterSquareType?) throws {
        let ts = "2026-09-29T00:00:00.000Z"
        let row = CoreBoardDefault(
            id: "cbd-1", userId: "u1", timeframe: .daily, corePoolIds: [], coreDefaultTaskIds: [],
            defaultBoardSize: size, defaultCenterType: centre, createdAt: ts, updatedAt: ts
        )
        try db.write { try row.insert($0) }
    }

    func test_applyClearableFieldNulls_coreBoardDefaults_clearsAbsentOverridesOnLocalRow() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try seedCoreDefault(db, size: .three, centre: .free)

        // A winning remote doc that omits BOTH overrides (a peer cleared them).
        try db.write { conn in
            try SyncService.applyClearableFieldNulls(db: conn, grdbTable: "core_board_defaults", cleaned: ["id": "cbd-1"])
        }

        let row = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: "u1", timeframe: .daily))
        XCTAssertNil(row.defaultBoardSize)
        XCTAssertNil(row.defaultCenterType)
    }

    func test_applyClearableFieldNulls_coreBoardDefaults_leavesPresentAlone() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try seedCoreDefault(db, size: .three, centre: .free)

        // Remote carries a size but no centre → only the centre NULLs.
        try db.write { conn in
            try SyncService.applyClearableFieldNulls(
                db: conn, grdbTable: "core_board_defaults", cleaned: ["id": "cbd-1", "defaultBoardSize": 3]
            )
        }

        let row = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: "u1", timeframe: .daily))
        XCTAssertEqual(row.defaultBoardSize, .three, "raw SQL NULL-out only touches ABSENT fields")
        XCTAssertNil(row.defaultCenterType)
    }
}
