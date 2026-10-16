import XCTest
import GRDB
@testable import OYBC

/// Task/window rework slice 1 (docs/TASK_WINDOW_REWORK.md) — the per-placement
/// parameters on `BoardTask`: the normaliser (vector-pinned against the TS
/// `normalizePlacementFields`), the GRDB round trip through the v45 columns,
/// and the wire shape (`childTargets` crosses as a native array).
final class PlacementFieldsTests: XCTestCase {

    // MARK: - Fixture

    private struct FixEntry: Decodable { let childId: String; let target: CountValue }
    private struct FixFields: Decodable {
        let targetOverride: CountValue?
        let targetKind: String?
        let childTargets: [FixEntry]?
        let titleOverride: String?
    }
    private struct Vector: Decodable { let name: String; let input: FixFields; let expected: FixFields }
    private struct Fixture: Decodable { let vectors: [Vector] }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "placementFieldsVectors", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testNormalizedPlacementFields_matchesTheSharedVectors() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.vectors.count, 10)
        for v in fixture.vectors {
            let out = BoardTask.normalizedPlacementFields(
                targetOverride: v.input.targetOverride,
                targetKind: v.input.targetKind.flatMap(CountKind.init(rawValue:)),
                childTargets: v.input.childTargets?.map { PlacementChildTarget(childId: $0.childId, target: $0.target) },
                titleOverride: v.input.titleOverride
            )
            XCTAssertEqual(out.targetOverride, v.expected.targetOverride, v.name)
            XCTAssertEqual(out.targetKind?.rawValue, v.expected.targetKind, v.name)
            XCTAssertEqual(
                out.childTargets?.map { [$0.childId, "\($0.target)"] },
                v.expected.childTargets?.map { [$0.childId, "\($0.target)"] },
                v.name
            )
            XCTAssertEqual(out.titleOverride, v.expected.titleOverride, v.name)
        }
    }

    // MARK: - GRDB round trip + wire

    private func placement(_ over: (inout BoardTask) -> Void = { _ in }) -> BoardTask {
        var bt = BoardTask(
            id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0, isCenter: false,
            createdAt: "2026-10-16T00:00:00.000Z", updatedAt: "2026-10-16T00:00:00.000Z", version: 1
        )
        bt.boardId = "b1"
        over(&bt)
        return bt
    }

    /// `board_tasks` carries foreign keys to `boards` / `tasks`.
    private func seededDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try LinkedWindowKit.seedUser(db)
        try db.saveBoard(LinkedWindowKit.board(id: "b1", startDate: "2026-10-01T00:00:00.000Z", endDate: "2026-10-31T23:59:59.999Z"))
        try db.saveTask(LinkedWindowKit.task("t1"))
        return db
    }

    func testRoundTrip_throughTheV45Columns_keepsEveryParameter() throws {
        let db = try seededDb()
        let row = BoardTask(
            id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0, isCenter: false,
            targetOverride: 70, targetKind: .discrete,
            childTargets: [PlacementChildTarget(childId: "z", target: 2), PlacementChildTarget(childId: "y", target: 3)],
            titleOverride: "  Read 70 pages ",
            createdAt: "2026-10-16T00:00:00.000Z", updatedAt: "2026-10-16T00:00:00.000Z", version: 1
        )
        try db.write { try row.save($0) }
        let back = try XCTUnwrap(db.read { try BoardTask.fetchOne($0, key: "bt1") })
        XCTAssertEqual(back.targetOverride, 70)
        XCTAssertEqual(back.targetKind, .discrete)
        XCTAssertEqual(back.childTargets, [PlacementChildTarget(childId: "y", target: 3), PlacementChildTarget(childId: "z", target: 2)], "sorted by childId")
        XCTAssertEqual(back.titleOverride, "Read 70 pages", "trimmed")
        // Stored as sorted-keys JSON text.
        let stored = try db.read { try String.fetchOne($0, sql: "SELECT childTargets FROM board_tasks WHERE id = 'bt1'") }
        XCTAssertEqual(stored, #"[{"childId":"y","target":3},{"childId":"z","target":2}]"#)
    }

    func testAbsentParameters_decodeAbsent_andEncodeNoKeys() throws {
        let db = try seededDb()
        try db.write { try self.placement().save($0) }
        let back = try XCTUnwrap(db.read { try BoardTask.fetchOne($0, key: "bt1") })
        XCTAssertNil(back.targetOverride); XCTAssertNil(back.targetKind); XCTAssertNil(back.childTargets); XCTAssertNil(back.titleOverride)
        let json = SyncQueueBuilder.encodePayload(back)
        for key in ["targetOverride", "targetKind", "childTargets", "titleOverride"] {
            XCTAssertFalse(json.contains("\"\(key)\""), "absent ⇒ no key on the wire, so the clearable-field delete applies")
        }
    }

    func testWire_childTargetsCrossesAsANativeArray_andAPulledArrayDecodes() throws {
        let row = placement { $0.childTargets = [PlacementChildTarget(childId: "a", target: 1.5)] }
        let json = SyncQueueBuilder.encodePayload(row)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertTrue(dict["childTargets"] is String, "GRDB / queue payload holds the JSON text")
        let wire = SyncWirePayload.expandJSONStrings(dict)
        let arr = try XCTUnwrap(wire["childTargets"] as? [[String: Any]])
        XCTAssertEqual(arr.first?["childId"] as? String, "a")
        XCTAssertEqual(arr.first?["target"] as? Double, 1.5)

        // A pulled payload (native array) decodes too, and a bad kind falls back to absent.
        var pulled = wire
        pulled["targetKind"] = "hours"
        pulled["targetOverride"] = 4
        let decoded = try JSONDecoder().decode(BoardTask.self, from: JSONSerialization.data(withJSONObject: pulled))
        XCTAssertEqual(decoded.childTargets, [PlacementChildTarget(childId: "a", target: 1.5)])
        XCTAssertEqual(decoded.targetOverride, 4)
        XCTAssertNil(decoded.targetKind, "an unknown kind is dropped, the override kept")
    }

    func testPulledDoc_isStoredCanonical_andAFreeTextTitleIsNeverExpanded() throws {
        let db = try seededDb()
        // A messy remote doc: orphan kind, untrimmed title, unsorted + bad childTargets.
        let doc: [String: Any] = [
            "id": "bt1", "boardId": "b1", "taskId": "t1", "row": 0, "col": 0, "isCenter": false,
            "targetKind": "discrete", "titleOverride": "  [1]  ",
            "childTargets": [["childId": "z", "target": 2], ["childId": "", "target": 1], ["childId": "a", "target": 0.5]],
            "createdAt": "2026-10-16T00:00:00.000Z", "updatedAt": "2026-10-16T00:00:00.000Z", "version": 1, "isDeleted": false,
        ]
        try db.write { try AppDatabase.upsertPulledRecord(db: $0, grdbTable: "board_tasks", data: doc) }
        let row = try db.read { try Row.fetchOne($0, sql: "SELECT targetOverride, targetKind, childTargets, titleOverride FROM board_tasks WHERE id = 'bt1'") }
        XCTAssertNil(row?["targetOverride"] as Double?)
        XCTAssertNil(row?["targetKind"] as String?, "a kind without an override is dropped (NULLed)")
        XCTAssertEqual(row?["childTargets"] as String?, #"[{"childId":"a","target":0.5},{"childId":"z","target":2}]"#)
        XCTAssertEqual(row?["titleOverride"] as String?, "[1]", "trimmed; stored as text")

        let back = try XCTUnwrap(db.read { try BoardTask.fetchOne($0, key: "bt1") })
        let wire = SyncWirePayload.expandJSONStrings(
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SyncQueueBuilder.encodePayload(back).utf8)) as? [String: Any])
        )
        XCTAssertEqual(wire["titleOverride"] as? String, "[1]", "a per-board title is free text, never expanded to JSON")
        XCTAssertTrue(wire["childTargets"] is [Any], "the JSON-text column still crosses as a native array")
    }
}
