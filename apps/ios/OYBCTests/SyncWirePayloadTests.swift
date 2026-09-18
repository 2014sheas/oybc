import XCTest
@testable import OYBC

/// Pins `SyncWirePayload.expandJSONStrings` — the Firestore wire shaping
/// `SyncService.writeFirestoreDoc` runs every pushed document through
/// (docs/SYNC_STRATEGY.md; issue #488).
///
/// #488 claimed iOS pushes `RecurringBoardTemplate`'s JSON-TEXT columns
/// (`sources`, `poolIds`, `manualTaskIds`, `removedTaskIds`,
/// `manualTaskVary`, `seedTaskIds`) to Firestore as JSON *strings*, which
/// would make web's Zod pull validation skip the row. That's false — GRDB
/// stores them as strings, but `expandJSONStrings` turns them into native
/// arrays/dicts before the doc is written. This file proves BOTH halves:
/// the pre-expansion payload really does carry strings (the hazard is
/// real), and the post-expansion payload carries native arrays/objects
/// (the fix closes it).
final class SyncWirePayloadTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTemplate() -> RecurringBoardTemplate {
        let now = "2026-09-18T00:00:00.000Z"
        return RecurringBoardTemplate(
            id: "tpl-1",
            userId: "u1",
            name: "Daily Workout",
            timeframe: .daily,
            boardSize: 5,
            centerSquareType: .free,
            isRandomized: false,
            seedTaskIds: [],
            poolIds: ["p1"],
            manualTaskIds: ["t1"],
            removedTaskIds: [],
            sources: [
                BoardSource(
                    sourceId: "s1",
                    kind: .board,
                    min: 1,
                    max: nil,
                    excludedTaskIds: ["x1"],
                    filter: .todo,
                    memberRules: ["t9": BoardSourceMemberRule(target: 5, vary: .little, split: nil, parts: nil)]
                )
            ],
            manualTaskVary: ["t1": .lot],
            lastSpawnedWindowKey: nil,
            isActive: true,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    /// Encodes `template` the same way `SyncQueueBuilder.makeItem` /
    /// `SyncService`'s push path do, then decodes the JSON string back into
    /// a `[String: Any]` dictionary — the pre-expansion shape a Firestore
    /// write would see if `expandJSONStrings` were never applied.
    private func encodeToDict(_ template: RecurringBoardTemplate) throws -> [String: Any] {
        let json = SyncQueueBuilder.encodePayload(template)
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    // MARK: - The hazard is real: GRDB/Codable encodes these as strings

    func testPreExpansion_JSONTextColumnsAreStrings() throws {
        let dict = try encodeToDict(makeTemplate())

        XCTAssertTrue(dict["sources"] is String, "sources should be a JSON string before expansion")
        XCTAssertTrue(dict["poolIds"] is String, "poolIds should be a JSON string before expansion")
        XCTAssertTrue(dict["manualTaskIds"] is String, "manualTaskIds should be a JSON string before expansion")
        XCTAssertTrue(dict["manualTaskVary"] is String, "manualTaskVary should be a JSON string before expansion")
        XCTAssertTrue(dict["seedTaskIds"] is String, "seedTaskIds should be a JSON string before expansion")
        XCTAssertTrue(dict["removedTaskIds"] is String, "removedTaskIds is a JSON-string column before expansion")
    }

    // MARK: - The fix closes it: expandJSONStrings restores native shapes

    func testExpansion_RestoresNativeArraysAndObjects() throws {
        let dict = try encodeToDict(makeTemplate())
        let wire = SyncWirePayload.expandJSONStrings(dict)

        guard let sources = wire["sources"] as? [[String: Any]], sources.count == 1 else {
            return XCTFail("expected sources to expand to a one-element array of dicts")
        }
        let source = sources[0]

        guard let memberRules = source["memberRules"] as? [String: Any] else {
            return XCTFail("expected memberRules to expand to a dict")
        }
        guard let t9Rule = memberRules["t9"] as? [String: Any] else {
            return XCTFail("expected memberRules[\"t9\"] to expand to a dict")
        }
        XCTAssertEqual(t9Rule["target"] as? Int, 5)
        XCTAssertEqual(t9Rule["vary"] as? Int, VaryLevel.little.rawValue)

        XCTAssertEqual(source["excludedTaskIds"] as? [String], ["x1"])

        // `max == nil` is encoded as an EXPLICIT JSON `null` inside the
        // `sources` string (BoardSource's custom encoder). Only TOP-level
        // NSNull values are dropped by expandJSONStrings — a nested null
        // survives as NSNull inside the expanded dict.
        XCTAssertTrue(source["max"] is NSNull, "nested null inside sources should survive expansion as NSNull")

        XCTAssertEqual(wire["manualTaskVary"] as? [String: Int], ["t1": VaryLevel.lot.rawValue])
        XCTAssertEqual(wire["poolIds"] as? [String], ["p1"])
        XCTAssertEqual(wire["manualTaskIds"] as? [String], ["t1"])
        XCTAssertNotNil(wire["seedTaskIds"] as? [String])
        XCTAssertEqual(wire["removedTaskIds"] as? [String], [])
    }

    // MARK: - Edge cases

    func testExpansion_DropsTopLevelNSNull() {
        let dict: [String: Any] = ["a": "keep", "b": NSNull()]
        let wire = SyncWirePayload.expandJSONStrings(dict)

        XCTAssertEqual(wire["a"] as? String, "keep")
        XCTAssertNil(wire["b"])
        XCTAssertFalse(wire.keys.contains("b"))
    }

    func testExpansion_NonJSONStringsPassThroughUnchanged() {
        let dict: [String: Any] = [
            "notArray": "[not json",
            "notObject": "{plain",
            "plainDate": "2026-09-18",
        ]
        let wire = SyncWirePayload.expandJSONStrings(dict)

        XCTAssertEqual(wire["notArray"] as? String, "[not json")
        XCTAssertEqual(wire["notObject"] as? String, "{plain")
        XCTAssertEqual(wire["plainDate"] as? String, "2026-09-18")
    }
}
