import XCTest
import GRDB
@testable import OYBC

/// Codec + migration coverage for Board Sources §Member rules (B1,
/// docs/BOARD_SOURCES.md).
///
/// The vector-pinned arithmetic lives in `MemberRuleVectorTests`; this suite
/// covers the persistence edges the fixture can't reach: that a pre-B1
/// six-field `BoardSource` blob still decodes, that a rule-less source
/// re-encodes byte-identically (no `memberRules` key at all), that
/// web-shaped rules decode, that the wizard-draft blob gained
/// `manualTaskVary` additively (still `v: 2`), and that GRDB v31 added the
/// `manualTaskVary` column the template record round-trips through.
final class MemberRulesCodecTests: XCTestCase {

    private let sixField =
        #"{"sourceId":"s1","kind":"board","min":0,"max":null,"excludedTaskIds":[],"filter":"all"}"#

    // MARK: - BoardSource

    func testOldSixFieldBlobDecodesWithNilRules() throws {
        let source = try JSONDecoder().decode(BoardSource.self, from: Data(sixField.utf8))
        XCTAssertNil(source.memberRules)
    }

    func testRulelessSourceEncodesWithoutMemberRulesKey() throws {
        let source = try JSONDecoder().decode(BoardSource.self, from: Data(sixField.utf8))
        let json = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        XCTAssertFalse(json.contains("memberRules"))

        var empty = source
        empty.memberRules = [:]
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(empty), as: UTF8.self).contains("memberRules"),
            "empty rules must be omitted too"
        )
    }

    func testRulesRoundTrip() throws {
        var source = try JSONDecoder().decode(BoardSource.self, from: Data(sixField.utf8))
        source.memberRules = [
            "t1": BoardSourceMemberRule(target: 5, vary: .little),
            "C": BoardSourceMemberRule(
                split: true,
                parts: [
                    "c1": BoardSourcePartRule(target: 2, vary: .lot),
                    "c2": BoardSourcePartRule(excluded: true),
                ]
            ),
        ]
        let back = try JSONDecoder().decode(
            BoardSource.self,
            from: try JSONEncoder().encode(source)
        )
        XCTAssertEqual(back.memberRules, source.memberRules)
        XCTAssertEqual(back.memberRules?["C"]?.parts?["c1"]?.vary, .lot)
    }

    func testWebShapedRulesDecode() throws {
        let json = #"{"sourceId":"s1","kind":"pool","min":1,"max":3,"excludedTaskIds":["x"],"filter":"todo","#
            + #""memberRules":{"t1":{"vary":2},"C":{"split":true,"parts":{"c1":{"excluded":true}}}}}"#
        let source = try JSONDecoder().decode(BoardSource.self, from: Data(json.utf8))
        XCTAssertEqual(source.memberRules?["t1"]?.vary, .lot)
        XCTAssertEqual(source.memberRules?["C"]?.parts?["c1"]?.excluded, true)
        XCTAssertEqual(source.memberRules?["C"]?.split, true)
    }

    // MARK: - Wizard draft blob

    func testDraftPayloadManualTaskVaryAdditiveV2() throws {
        let v2NoVary = #"{"v":2,"poolIds":[],"manualTaskIds":["t1"],"removedTaskIds":[],"sources":[]}"#
        XCTAssertEqual(RecurringDraftMixPayload.decoded(from: v2NoVary).manualTaskVary, [:])

        var payload = RecurringDraftMixPayload.decoded(from: v2NoVary)
        payload.manualTaskVary = ["t1": .lot]
        let json = try XCTUnwrap(payload.encoded())
        XCTAssertTrue(json.contains(#""v":2"#), "the blob version stays 2 — this key is additive")
        XCTAssertEqual(RecurringDraftMixPayload.decoded(from: json).manualTaskVary, ["t1": .lot])

        let empty = try XCTUnwrap(RecurringDraftMixPayload.decoded(from: v2NoVary).encoded())
        XCTAssertFalse(empty.contains("manualTaskVary"), "an empty map must be omitted")
    }

    /// Ruling R11 — an out-of-range level drops the WHOLE map on iOS (Swift's
    /// `VaryLevel: Int` decode is all-or-nothing) where web's codec drops only
    /// the bad key. Both converge to "no dice" for that key; B3 only ever
    /// writes valid levels.
    func testDraftPayloadInvalidVaryLevelYieldsNoDice() throws {
        let corrupt = #"{"v":2,"poolIds":["p1"],"manualTaskIds":["t1"],"removedTaskIds":["x1"],"#
            + #""sources":[{"sourceId":"p1","kind":"pool","min":0,"max":null,"excludedTaskIds":[],"#
            + #""filter":"all"}],"manualTaskVary":{"t1":7}}"#
        let decoded = RecurringDraftMixPayload.decoded(from: corrupt)
        XCTAssertEqual(decoded.manualTaskVary, [:])
        // The distinguishing assertions: a STRICT decode of the dice would
        // throw out of `init(from:)`, `decoded(from:)` would fall back to the
        // all-empty mix, and the `[:]` above would STILL hold — while the
        // user's whole draft was silently wiped. Only these catch that.
        XCTAssertEqual(
            decoded.manualTaskIds, ["t1"],
            "only the dice are dropped — the draft survives"
        )
        XCTAssertEqual(decoded.poolIds, ["p1"])
        XCTAssertEqual(decoded.removedTaskIds, ["x1"])
        let sources = try XCTUnwrap(decoded.sources)
        XCTAssertEqual(sources.map(\.sourceId), ["p1"])
    }

    // MARK: - GRDB v31

    /// Minimal template builder — mirrors `RecurringBoardTemplatesTests`'
    /// (which is `private` to that class, so it can't be shared directly).
    private func makeTemplate(
        id: String,
        manualTaskVary: [String: VaryLevel]?
    ) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id,
            userId: "u1",
            name: "Daily Workout",
            timeframe: .daily,
            boardSize: 5,
            centerSquareType: .free,
            isRandomized: false,
            seedTaskIds: (0..<24).map { "task-\($0)" },
            manualTaskVary: manualTaskVary,
            lastSpawnedWindowKey: nil,
            isActive: true,
            createdAt: "2026-05-01T00:00:00.000Z",
            updatedAt: "2026-05-01T00:00:00.000Z",
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    func testTemplateManualTaskVaryColumnAndRoundTrip() throws {
        let db = try AppDatabase.makeTestInstance()

        try db.read { d in
            let columns = try d.columns(in: "recurring_board_templates").map(\.name)
            XCTAssertTrue(columns.contains("manualTaskVary"), "v31 must add the column; got \(columns)")
        }

        let withVary = makeTemplate(id: "tpl-vary", manualTaskVary: ["t1": .little])
        try db.saveRecurringBoardTemplate(withVary)
        let fetched = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: "tpl-vary"))
        XCTAssertEqual(fetched.manualTaskVary, ["t1": .little])

        let withoutVary = makeTemplate(id: "tpl-none", manualTaskVary: nil)
        try db.saveRecurringBoardTemplate(withoutVary)
        let fetchedNil = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: "tpl-none"))
        XCTAssertNil(fetchedNil.manualTaskVary, "nil must round-trip as nil, not an empty map")

        // Tri-state twin of `sources`: a malformed JSON string in the column
        // decodes to nil — never a silently manufactured "stamped, empty" map.
        try db.write { d in
            try d.execute(
                sql: "UPDATE recurring_board_templates SET manualTaskVary = ? WHERE id = ?",
                arguments: ["not json", "tpl-vary"]
            )
        }
        let fetchedMalformed = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: "tpl-vary"))
        XCTAssertNil(fetchedMalformed.manualTaskVary, "a malformed column value must decode to nil")
    }

    /// The sync-wire contract the encode comment claims: the key is OMITTED
    /// when nil (`.optional()` in the shared schema), never an explicit null,
    /// and carried as a JSON *string* when present — exactly like `sources`.
    func testTemplateManualTaskVaryOmittedFromWireWhenNil() throws {
        let none = String(
            decoding: try JSONEncoder().encode(makeTemplate(id: "t", manualTaskVary: nil)),
            as: UTF8.self
        )
        XCTAssertFalse(none.contains("manualTaskVary"), "nil must omit the key, not write null")

        let some = try JSONEncoder().encode(makeTemplate(id: "t", manualTaskVary: ["t1": .lot]))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: some) as? [String: Any])
        let raw = try XCTUnwrap(dict["manualTaskVary"] as? String, "must be a JSON-string column")
        XCTAssertEqual(
            try JSONDecoder().decode([String: VaryLevel].self, from: Data(raw.utf8)),
            ["t1": .lot]
        )
    }
}
