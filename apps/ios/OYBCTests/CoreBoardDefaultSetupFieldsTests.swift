import XCTest
import GRDB
import FirebaseFirestore
@testable import OYBC

/// Per-timeframe core-board size + centre (docs/POOLS_RECURRING.md
/// §Per-timeframe size + centre, 2026-09-29) — the storage/ops half on iOS:
/// `CoreBoardDefault.defaultBoardSize` / `defaultCenterType` decode + encode,
/// the GRDB v36 columns, the tri-state `upsertCoreBoardDefaultAndEnqueue`
/// patch (keep / set / clear), and the wire shape a cleared override pushes
/// (key ABSENT → `FieldValue.delete()` via the clearable-fields mechanism).
/// iOS twin of web's `coreBoardDefaults.test.ts` size/centre block.
@MainActor
final class CoreBoardDefaultSetupFieldsTests: XCTestCase {

    private let userId = "u1"
    private let ts = "2026-09-29T00:00:00.000Z"

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func rowJSON(extra: [String: Any] = [:]) -> [String: Any] {
        var dict: [String: Any] = [
            "id": "cbd-1", "userId": userId, "timeframe": "daily",
            "corePoolIds": "[]", "coreDefaultTaskIds": "[]",
            "createdAt": ts, "updatedAt": ts, "version": 1, "isDeleted": false,
        ]
        for (k, v) in extra { dict[k] = v }
        return dict
    }

    private func decode(_ dict: [String: Any]) throws -> CoreBoardDefault {
        try JSONDecoder().decode(CoreBoardDefault.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func encodeToDict(_ row: CoreBoardDefault) throws -> [String: Any] {
        let json = SyncQueueBuilder.encodePayload(row)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as? [String: Any])
    }

    // MARK: - Decode

    func test_decode_preFeatureRow_bothAbsent_isNil() throws {
        let row = try decode(rowJSON())
        XCTAssertNil(row.defaultBoardSize)
        XCTAssertNil(row.defaultCenterType)
    }

    func test_decode_presentValues() throws {
        let row = try decode(rowJSON(extra: ["defaultBoardSize": 4, "defaultCenterType": "none"]))
        XCTAssertEqual(row.defaultBoardSize, .four)
        XCTAssertEqual(row.defaultCenterType, DefaultCenterSquareType.none)
    }

    func test_decode_explicitNull_isNil() throws {
        let row = try decode(rowJSON(extra: ["defaultBoardSize": NSNull(), "defaultCenterType": NSNull()]))
        XCTAssertNil(row.defaultBoardSize)
        XCTAssertNil(row.defaultCenterType)
    }

    func test_decode_outOfRangeOrUnknown_isNil_neverThrows() throws {
        // 6 is not a board size; "chosen" is a per-board pick, never a default.
        let row = try decode(rowJSON(extra: ["defaultBoardSize": 6, "defaultCenterType": "chosen"]))
        XCTAssertNil(row.defaultBoardSize)
        XCTAssertNil(row.defaultCenterType)
        // A wrong TYPE is tolerated the same way (lenient inherit, not a dropped row).
        let typed = try decode(rowJSON(extra: ["defaultBoardSize": "5", "defaultCenterType": 3]))
        XCTAssertNil(typed.defaultBoardSize)
        XCTAssertNil(typed.defaultCenterType)
    }

    // MARK: - Encode (wire shape)

    func test_encode_nilEncodesAsAbsent_notNull() throws {
        let dict = try encodeToDict(try decode(rowJSON()))
        XCTAssertFalse(dict.keys.contains("defaultBoardSize"), "nil must be ABSENT so the push path can FieldValue.delete() it")
        XCTAssertFalse(dict.keys.contains("defaultCenterType"))
    }

    func test_encode_roundTripsRawValues() throws {
        let dict = try encodeToDict(try decode(rowJSON(extra: ["defaultBoardSize": 3, "defaultCenterType": "free"])))
        XCTAssertEqual(dict["defaultBoardSize"] as? Int, 3, "size travels as a plain Int (web Zod: 3 | 4 | 5)")
        XCTAssertEqual(dict["defaultCenterType"] as? String, "free", "centre travels as its raw string (web Zod: free | none)")
        let back = try decode(dict)
        XCTAssertEqual(back.defaultBoardSize, .three)
        XCTAssertEqual(back.defaultCenterType, .free)
    }

    /// The full push shaping a cleared override goes through: encode (key
    /// absent) → `expandJSONStrings` → clearable-field deletes. Same shape
    /// `SyncService.writeFirestoreDoc` assembles.
    func test_wire_clearedOverride_stampsFieldValueDelete() throws {
        var wire = SyncWirePayload.expandJSONStrings(try encodeToDict(try decode(rowJSON())))
        SyncService.applyClearableFieldDeletes(collection: "coreBoardDefaults", cleaned: &wire)
        XCTAssertTrue(wire["defaultBoardSize"] is FieldValue)
        XCTAssertTrue(wire["defaultCenterType"] is FieldValue)
        XCTAssertNil(wire["sealedAt"], "boards-only fields never leak onto a coreBoardDefaults doc")
    }

    func test_wire_setOverride_isPushedAsValue() throws {
        var wire = SyncWirePayload.expandJSONStrings(
            try encodeToDict(try decode(rowJSON(extra: ["defaultBoardSize": 5, "defaultCenterType": "none"])))
        )
        SyncService.applyClearableFieldDeletes(collection: "coreBoardDefaults", cleaned: &wire)
        XCTAssertEqual(wire["defaultBoardSize"] as? Int, 5)
        XCTAssertEqual(wire["defaultCenterType"] as? String, "none")
    }

    // MARK: - v36 migration

    func test_v36_columnsExist_andArePersistedByGRDB() throws {
        let db = try makeDb()
        let columns = try db.read { try $0.columns(in: "core_board_defaults") }
        let size = try XCTUnwrap(columns.first { $0.name == "defaultBoardSize" })
        let centre = try XCTUnwrap(columns.first { $0.name == "defaultCenterType" })
        XCTAssertFalse(size.isNotNull, "override columns are nullable (NULL = inherit)")
        XCTAssertFalse(centre.isNotNull)

        try seedUser(db)
        try db.write { try self.decode(self.rowJSON(extra: ["defaultBoardSize": 4, "defaultCenterType": "free"])).insert($0) }
        let fetched = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: userId, timeframe: .daily))
        XCTAssertEqual(fetched.defaultBoardSize, .four)
        XCTAssertEqual(fetched.defaultCenterType, .free)
    }

    /// A row written by a pre-v36 client has no values in the new columns —
    /// simulated by a raw INSERT that names only the pre-v36 columns.
    func test_v36_preV36RowDecodesAsInherit() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.write { conn in
            try conn.execute(
                sql: """
                INSERT INTO core_board_defaults
                  (id, userId, timeframe, corePoolIds, coreDefaultTaskIds, createdAt, updatedAt, version, isDeleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["cbd-old", userId, "weekly", "[\"p1\"]", "[]", ts, ts, 1, false]
            )
        }
        let fetched = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: userId, timeframe: .weekly))
        XCTAssertEqual(fetched.corePoolIds, ["p1"])
        XCTAssertNil(fetched.defaultBoardSize)
        XCTAssertNil(fetched.defaultCenterType)
        XCTAssertFalse(hasExplicitCoreBoardSetup(fetched))
    }

    // MARK: - Upsert round-trip (keep / set / clear)

    func test_upsert_setThenKeepThenClear() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Create with both overrides set.
        let created = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .monthly, corePoolIds: [], coreDefaultTaskIds: [],
            defaultBoardSize: .set(.three), defaultCenterType: .set(DefaultCenterSquareType.none), now: now
        )
        XCTAssertEqual(created.version, 1)
        XCTAssertEqual(created.defaultBoardSize, .three)
        XCTAssertEqual(created.defaultCenterType, DefaultCenterSquareType.none)

        // A pools-only save (the pre-feature call shape — `.keep` by default)
        // must NOT stomp the overrides.
        let kept = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .monthly, corePoolIds: ["p1"], coreDefaultTaskIds: ["t1"], now: now
        )
        XCTAssertEqual(kept.id, created.id)
        XCTAssertEqual(kept.version, 2)
        XCTAssertEqual(kept.defaultBoardSize, .three)
        XCTAssertEqual(kept.defaultCenterType, DefaultCenterSquareType.none)
        XCTAssertEqual(kept.corePoolIds, ["p1"])

        // Clear ONE, keep the other.
        let clearedSize = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .monthly, corePoolIds: ["p1"], coreDefaultTaskIds: ["t1"],
            defaultBoardSize: .set(nil), now: now
        )
        XCTAssertEqual(clearedSize.version, 3)
        XCTAssertNil(clearedSize.defaultBoardSize)
        XCTAssertEqual(clearedSize.defaultCenterType, DefaultCenterSquareType.none)

        // Clear the other; the STORED row (not just the returned one) is NULL.
        let clearedBoth = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .monthly, corePoolIds: ["p1"], coreDefaultTaskIds: ["t1"],
            defaultCenterType: .set(nil), now: now
        )
        XCTAssertEqual(clearedBoth.version, 4)
        let stored = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: userId, timeframe: .monthly))
        XCTAssertNil(stored.defaultBoardSize)
        XCTAssertNil(stored.defaultCenterType)
        XCTAssertEqual(try db.fetchCoreBoardDefaults(userId: userId).count, 1, "still one row per timeframe")

        // The enqueued payload for the cleared row carries NEITHER key.
        let queued = try db.read { try SyncQueueItem.fetchAll($0) }
            .filter { $0.entityType == "coreBoardDefaults" && $0.entityId == created.id }
        let last = try XCTUnwrap(queued.last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: last.payload.data(using: .utf8)!) as? [String: Any])
        XCTAssertFalse(payload.keys.contains("defaultBoardSize"))
        XCTAssertFalse(payload.keys.contains("defaultCenterType"))
    }

    func test_upsertCorePoolIds_keepsOverrides() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        _ = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .yearly, corePoolIds: [], coreDefaultTaskIds: ["t1"],
            defaultBoardSize: .set(.five), defaultCenterType: .set(.free), now: now
        )
        let updated = try db.upsertCorePoolIdsAndEnqueue(userId: userId, timeframe: .yearly, corePoolIds: ["p9"], now: now)
        XCTAssertEqual(updated.corePoolIds, ["p9"])
        XCTAssertEqual(updated.coreDefaultTaskIds, ["t1"])
        XCTAssertEqual(updated.defaultBoardSize, .five)
        XCTAssertEqual(updated.defaultCenterType, .free)
    }

    func test_fieldPatch_semantics() {
        var stored: DefaultBoardSize? = .four
        CoreBoardDefaultFieldPatch<DefaultBoardSize>.keep.apply(to: &stored)
        XCTAssertEqual(stored, .four)
        CoreBoardDefaultFieldPatch<DefaultBoardSize>.set(.three).apply(to: &stored)
        XCTAssertEqual(stored, .three)
        CoreBoardDefaultFieldPatch<DefaultBoardSize>.set(nil).apply(to: &stored)
        XCTAssertNil(stored)
        stored = .five
        CoreBoardDefaultFieldPatch<DefaultBoardSize>.clear.apply(to: &stored)
        XCTAssertNil(stored)

        // The sharp edge, pinned: `.set(DefaultCenterSquareType.none)` SETS
        // "no free space"; a bare `.set(.none)` would be `.set(nil)` = clear.
        var centre: DefaultCenterSquareType? = .free
        CoreBoardDefaultFieldPatch<DefaultCenterSquareType>.set(DefaultCenterSquareType.none).apply(to: &centre)
        XCTAssertEqual(centre, DefaultCenterSquareType.none)
        CoreBoardDefaultFieldPatch<DefaultCenterSquareType>.clear.apply(to: &centre)
        XCTAssertNil(centre)
    }
}
