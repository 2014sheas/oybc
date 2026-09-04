import XCTest
@testable import OYBC

/// Cross-platform Board Sources enforcement (Board Sources rework P1,
/// docs/BOARD_SOURCES.md).
///
/// Runs the shared fixture (`Fixtures/boardSourceVectors.json`, synced from
/// `packages/shared/tests/fixtures/boardSourceVectors.json`) through iOS's
/// `BoardSources` (`Helpers/BoardSources.swift`). The SAME fixture is
/// exercised on the shared side by
/// `packages/shared/tests/algorithms/boardSources.test.ts` — both suites
/// passing against byte-identical vectors, with the identical seeded LCG,
/// is what proves the two hand-mirrored implementations agree (the
/// placementResolutionVectors precedent).
final class BoardSourceVectorTests: XCTestCase {

    /// Deterministic uniform [0,1) LCG — twin of bingo-core's
    /// `tests/seededRng.ts` `makeSeededRng`. Same seed ⇒ same sequence.
    private final class SeededRng {
        private var state: UInt32
        init(seed: UInt32) { state = seed }
        func next() -> Double {
            state = state &* 1664525 &+ 1013904223
            return Double(state) / 4294967296.0
        }
    }

    // MARK: - Fixture decoding

    private struct RawSource: Decodable {
        let sourceId: String
        let kind: String
        let min: Int
        let max: Int?
        let excludedTaskIds: [String]
        let filter: String
        let supplyTaskIds: [String]?

        var boardSource: BoardSource {
            BoardSource(
                sourceId: sourceId,
                kind: BoardSource.Kind(rawValue: kind) ?? .pool,
                min: min,
                max: max,
                excludedTaskIds: excludedTaskIds,
                filter: BoardSource.Filter(rawValue: filter) ?? .all
            )
        }

        var supply: BoardSources.Supply {
            BoardSources.Supply(source: boardSource, supplyTaskIds: supplyTaskIds ?? [])
        }
    }

    private struct RawCapacityExpected: Decodable {
        let uniqueCandidateCount: Int
        let cappedBound: Int
        let capacity: Int
    }

    private struct CapacityVector: Decodable {
        let name: String
        let sources: [RawSource]
        let manualTaskIds: [String]
        let expected: RawCapacityExpected
    }

    private struct RawSelectionExpected: Decodable {
        let ok: Bool
        let taskIds: [String]?
        let shortBy: Int?
    }

    private struct SelectionVector: Decodable {
        let name: String
        let sources: [RawSource]
        let manualTaskIds: [String]
        let cellCount: Int
        let rngSeed: UInt32
        let expected: RawSelectionExpected
    }

    private struct RawRecord: Decodable {
        let poolIds: [String]?
        let removedTaskIds: [String]?
        let sources: [RawSource]?
    }

    private struct RawMixFields: Decodable {
        let poolIds: [String]
        let removedTaskIds: [String]
    }

    private struct ConversionVector: Decodable {
        let name: String
        let record: RawRecord
        let expectedSources: [RawSource]
        let expectedMixFields: RawMixFields
    }

    private struct Fixture: Decodable {
        let capacityVectors: [CapacityVector]
        let selectionVectors: [SelectionVector]
        let conversionVectors: [ConversionVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: BoardSourceVectorTests.self).url(
            forResource: "boardSourceVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "boardSourceVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    // MARK: - Vectors

    func testCapacityVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.capacityVectors.isEmpty)
        for v in fixture.capacityVectors {
            let result = BoardSources.computeSourceCapacity(
                v.sources.map { $0.supply },
                manualTaskIds: v.manualTaskIds
            )
            XCTAssertEqual(result.uniqueCandidateCount, v.expected.uniqueCandidateCount, v.name)
            XCTAssertEqual(result.cappedBound, v.expected.cappedBound, v.name)
            XCTAssertEqual(result.capacity, v.expected.capacity, v.name)
        }
    }

    func testSelectionVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.selectionVectors.isEmpty)
        for v in fixture.selectionVectors {
            let rng = SeededRng(seed: v.rngSeed)
            let result = BoardSources.selectBoardTasks(
                supplies: v.sources.map { $0.supply },
                manualTaskIds: v.manualTaskIds,
                cellCount: v.cellCount,
                rng: { rng.next() }
            )
            switch result {
            case .ok(let taskIds):
                XCTAssertTrue(v.expected.ok, "\(v.name): expected short, got ok")
                XCTAssertEqual(taskIds, v.expected.taskIds, v.name)
            case .short(let shortBy):
                XCTAssertFalse(v.expected.ok, "\(v.name): expected ok, got short")
                XCTAssertEqual(shortBy, v.expected.shortBy, v.name)
            }
        }
    }

    func testConversionVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.conversionVectors.isEmpty)
        for v in fixture.conversionVectors {
            let sources = BoardSources.sourcesForRecord(
                sources: v.record.sources.map { $0.map { $0.boardSource } },
                poolIds: v.record.poolIds,
                removedTaskIds: v.record.removedTaskIds
            )
            XCTAssertEqual(sources, v.expectedSources.map { $0.boardSource }, v.name)
            let mixFields = BoardSources.mixFieldsFromSources(sources)
            XCTAssertEqual(mixFields.poolIds, v.expectedMixFields.poolIds, v.name)
            XCTAssertEqual(mixFields.removedTaskIds, v.expectedMixFields.removedTaskIds, v.name)
        }
    }

    // MARK: - Codec round-trips (iOS-side, beyond the shared vectors)

    /// `max: nil` must encode as an EXPLICIT JSON null — web's blob shape
    /// check requires the key present (`max === null || number`).
    func testBoardSourceEncodesExplicitNullMax() throws {
        let source = BoardSource(sourceId: "p1", kind: .pool)
        let data = try JSONEncoder().encode(source)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertTrue(dict.keys.contains("max"))
        XCTAssertTrue(dict["max"] is NSNull)
        // And the round-trip preserves the latch.
        let decoded = try JSONDecoder().decode(BoardSource.self, from: data)
        XCTAssertEqual(decoded, source)
    }

    /// A v1 draft-mix blob (no `sources` key) decodes forward by deriving
    /// [0, all] sources from the trio; a v2 blob round-trips verbatim.
    func testRecurringDraftMixPayloadV1ToV2() throws {
        let v1 = #"{"poolIds":["p1"],"manualTaskIds":["m1"],"removedTaskIds":["r1"]}"#
        let decoded = RecurringDraftMixPayload.decoded(from: v1)
        XCTAssertEqual(decoded.poolIds, ["p1"])
        XCTAssertEqual(
            decoded.sources,
            [BoardSource(sourceId: "p1", kind: .pool, min: 0, max: nil, excludedTaskIds: ["r1"], filter: .all)]
        )

        // v2 round-trip: sources survive verbatim, and the wire carries v: 2.
        let payload = RecurringDraftMixPayload(
            poolIds: [],
            manualTaskIds: ["m1"],
            removedTaskIds: [],
            sources: [BoardSource(sourceId: "b1", kind: .board, min: 1, max: 3, excludedTaskIds: [], filter: .todo)]
        )
        let encoded = try XCTUnwrap(payload.encoded())
        XCTAssertTrue(encoded.contains(#""v":2"#))
        let roundTripped = RecurringDraftMixPayload.decoded(from: encoded)
        XCTAssertEqual(roundTripped.sources, payload.sources)
        XCTAssertEqual(roundTripped.manualTaskIds, ["m1"])
    }

    /// The template's `sources` JSON-string column follows the trio's
    /// tri-state contract: nil omits the key; present round-trips.
    func testTemplateSourcesColumnTriState() throws {
        let template = RecurringBoardTemplate(
            id: "t1",
            userId: "u1",
            name: "T",
            timeframe: .daily,
            boardSize: 3,
            centerSquareType: .free,
            isRandomized: true,
            seedTaskIds: [],
            sources: [BoardSource(sourceId: "p1", kind: .pool)],
            isActive: true,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        let data = try JSONEncoder().encode(template)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sourcesString = try XCTUnwrap(dict["sources"] as? String)
        XCTAssertTrue(sourcesString.hasPrefix("["))
        let decoded = try JSONDecoder().decode(RecurringBoardTemplate.self, from: data)
        XCTAssertEqual(decoded.sources, template.sources)

        // nil sources → key omitted on the wire (pre-stamp), decodes nil.
        var preStamp = template
        preStamp.sources = nil
        let preStampData = try JSONEncoder().encode(preStamp)
        let preStampDict = try XCTUnwrap(JSONSerialization.jsonObject(with: preStampData) as? [String: Any])
        XCTAssertFalse(preStampDict.keys.contains("sources"))
        XCTAssertNil(try JSONDecoder().decode(RecurringBoardTemplate.self, from: preStampData).sources)
    }
}
