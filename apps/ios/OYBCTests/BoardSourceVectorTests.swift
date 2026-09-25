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
    ///
    /// A reference wrapper around the production value-type
    /// ``OYBC/SeededRng`` (B3 RC6 promoted the recurrence into the app
    /// target): the vectors below hand one generator to several calls, which
    /// wants shared mutable state.
    private final class SeededRng {
        private var rng: OYBC.SeededRng
        init(seed: UInt32) { rng = OYBC.SeededRng(seed: seed) }
        func next() -> Double { rng.next() }
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
        let counterFamilyByTaskId: [String: String]?
        let pinnedTaskId: String?
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
        let randomize: Bool
        let counterFamilyByTaskId: [String: String]?
        let pinnedTaskId: String?
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

    private struct RawConfigurationDetail: Decodable {
        let excludedCount: Int
        let memberRuleCount: Int
        let rangeNarrowed: Bool
        let filterChanged: Bool
        /// Absent key and JSON `null` both mean "filter unchanged".
        let filter: String?

        /// `filterChanged` is COMPUTED on the struct, so it falls out of
        /// synthesized equality — `testConfigurationVectors` asserts the
        /// fixture's raw boolean separately so the bit stays pinned.
        var detail: BoardSources.ConfigurationDetail {
            BoardSources.ConfigurationDetail(
                excludedCount: excludedCount,
                memberRuleCount: memberRuleCount,
                rangeNarrowed: rangeNarrowed,
                filter: filter.flatMap { BoardSource.Filter(rawValue: $0) }
            )
        }
    }

    /// Decodes `BoardSource` itself (not `RawSource`) — these vectors carry
    /// `memberRules`, which the supply-shaped `RawSource` deliberately omits.
    private struct ConfigurationVector: Decodable {
        let name: String
        let source: BoardSource
        let defaultFilter: String
        /// What the one-off prefill would seed right now; absent = no map.
        let seededTargetByTaskId: [String: Int]?
        let expected: RawConfigurationDetail
        let expectedHasConfiguration: Bool
    }

    private struct LossSentenceVector: Decodable {
        let name: String
        let detail: RawConfigurationDetail
        let expected: String?
    }

    private struct RawSeriesCandidate: Decodable, SeriesInstanceCandidate {
        let id: String
        let startDate: String
    }

    private struct RawEligibilityBoard: Decodable, SourceBoardCandidate {
        let status: BoardStatus
        let endDate: String?
        let sealedAt: String?
        let isDeleted: Bool
    }

    private struct EligibilityVector: Decodable {
        let name: String
        let board: RawEligibilityBoard
        let now: String
        let expected: Bool
    }

    private struct RawWindowCandidate: Decodable, SeriesWindowCandidate {
        let id: String
        let startDate: String
        let endDate: String?
    }

    private struct SeriesForWindowVector: Decodable {
        let name: String
        let candidates: [RawWindowCandidate]
        let reference: String
        let expectedId: String?
    }

    private struct SeriesInstanceVector: Decodable {
        let name: String
        let candidates: [RawSeriesCandidate]
        let expectedId: String
    }

    private struct RawReferenceTemplate: Decodable {
        let seedTaskIds: [String]
        let poolIds: [String]?
        let removedTaskIds: [String]?
        let manualTaskIds: [String]?
        let sources: [RawSource]?

        var template: RecurringBoardTemplate {
            RecurringBoardTemplate(
                id: "t-ref",
                userId: "u1",
                name: "T",
                timeframe: .daily,
                boardSize: 3,
                centerSquareType: .free,
                isRandomized: true,
                seedTaskIds: seedTaskIds,
                poolIds: poolIds,
                manualTaskIds: manualTaskIds,
                removedTaskIds: removedTaskIds,
                sources: sources.map { $0.map { $0.boardSource } },
                isActive: true,
                createdAt: "2026-01-01T00:00:00.000Z",
                updatedAt: "2026-01-01T00:00:00.000Z"
            )
        }
    }

    private struct ReferenceCase: Decodable {
        let taskId: String
        let expected: Bool
    }

    private struct ReferenceVector: Decodable {
        let name: String
        let template: RawReferenceTemplate
        let suppliesBySourceId: [String: [String]]
        let cases: [ReferenceCase]
    }

    private struct DoneFilterVector: Decodable {
        let name: String
        let source: BoardSource
        let supplyTaskIds: [String]
        let doneTaskIds: [String]
        let expected: [String]
    }

    private struct Fixture: Decodable {
        let capacityVectors: [CapacityVector]
        let selectionVectors: [SelectionVector]
        let conversionVectors: [ConversionVector]
        let configurationVectors: [ConfigurationVector]
        let lossSentenceVectors: [LossSentenceVector]
        let seriesInstanceVectors: [SeriesInstanceVector]
        let referenceVectors: [ReferenceVector]
        let doneFilterVectors: [DoneFilterVector]
        let eligibilityVectors: [EligibilityVector]
        let seriesForWindowVectors: [SeriesForWindowVector]
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
                manualTaskIds: v.manualTaskIds,
                counterFamilyByTaskId: v.counterFamilyByTaskId ?? [:],
                pinnedTaskId: v.pinnedTaskId
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
                randomize: v.randomize,
                rng: { rng.next() },
                counterFamilyByTaskId: v.counterFamilyByTaskId ?? [:],
                pinnedTaskId: v.pinnedTaskId
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

    /// Series-binding tie-break: latest startDate, lowest id on a tie. Run
    /// in both the fixture order and reversed — input order must never
    /// decide which instance supplies.
    func testSeriesInstanceVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.seriesInstanceVectors.isEmpty)
        for v in fixture.seriesInstanceVectors {
            XCTAssertEqual(BoardSources.pickSeriesInstance(v.candidates)?.id, v.expectedId, v.name)
            XCTAssertEqual(
                BoardSources.pickSeriesInstance(Array(v.candidates.reversed()))?.id,
                v.expectedId,
                "\(v.name) (reversed)"
            )
        }
        XCTAssertNil(BoardSources.pickSeriesInstance([RawSeriesCandidate]()))
    }

    /// Owner ruling 2026-09-24 — ended boards are never sources.
    func testEligibilityVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.eligibilityVectors.isEmpty)
        for v in fixture.eligibilityVectors {
            let now = try XCTUnwrap(parseISO8601Date(v.now), v.name)
            XCTAssertEqual(BoardSources.isEligibleSourceBoard(v.board, now: now), v.expected, v.name)
        }
    }

    /// Series binding for a window: the containing instance, else nil — in
    /// both orders (the tie-break is total).
    func testSeriesForWindowVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.seriesForWindowVectors.isEmpty)
        for v in fixture.seriesForWindowVectors {
            XCTAssertEqual(
                BoardSources.resolveSeriesInstanceForWindow(v.candidates, referenceIso: v.reference)?.id,
                v.expectedId,
                v.name
            )
            XCTAssertEqual(
                BoardSources.resolveSeriesInstanceForWindow(
                    Array(v.candidates.reversed()), referenceIso: v.reference
                )?.id,
                v.expectedId,
                "\(v.name) (reversed)"
            )
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

    /// Task Detail's "used in repeating boards" membership (2026-09 audit
    /// T2): hand-added OR in a source's available supply; ranges and the
    /// done-filter ignored; the stale `seedTaskIds` snapshot never read for
    /// a migrated record.
    func testReferenceVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.referenceVectors.isEmpty)
        for v in fixture.referenceVectors {
            XCTAssertFalse(v.cases.isEmpty, v.name)
            let template = v.template.template
            for c in v.cases {
                XCTAssertEqual(
                    BoardSources.templateReferencesTask(
                        template, taskId: c.taskId, suppliesBySourceId: v.suppliesBySourceId
                    ),
                    c.expected,
                    "\(v.name) — \(c.taskId)"
                )
            }
        }
    }

    /// The remove-confirm gate (owner ruling 2026-09-19): an untouched
    /// source removes instantly, a configured one asks first — and the
    /// detail names WHAT is configured.
    func testConfigurationVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.configurationVectors.isEmpty)
        for v in fixture.configurationVectors {
            let defaultFilter = try XCTUnwrap(
                BoardSource.Filter(rawValue: v.defaultFilter), v.name
            )
            let seeded = v.seededTargetByTaskId ?? [:]
            let detail = BoardSources.sourceConfiguration(
                v.source,
                defaultFilter: defaultFilter,
                seededTargetByTaskId: seeded
            )
            XCTAssertEqual(detail, v.expected.detail, v.name)
            // Computed, so outside synthesized equality — pin it against the
            // fixture's own boolean rather than against `filter != nil`,
            // which would be the implementation compared to itself.
            XCTAssertEqual(detail.filterChanged, v.expected.filterChanged, v.name)
            XCTAssertEqual(
                BoardSources.sourceHasConfiguration(
                    v.source,
                    defaultFilter: defaultFilter,
                    seededTargetByTaskId: seeded
                ),
                v.expectedHasConfiguration,
                v.name
            )
        }
    }

    /// The remove-confirm's loss sentence — pluralisation and the
    /// `"A, B and C."` join, pinned so the two platforms can't word it
    /// differently.
    func testLossSentenceVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.lossSentenceVectors.isEmpty)
        for v in fixture.lossSentenceVectors {
            XCTAssertEqual(
                BoardSources.removeSourceLossSentence(v.detail.detail),
                v.expected,
                v.name
            )
        }
    }

    /// The board-source done-filter ("Not done yet") — pool untouched,
    /// board `.all` untouched, board `.todo` drops done ids, excludes left
    /// for `resolveSourceAvailable`.
    func testDoneFilterVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.doneFilterVectors.isEmpty)
        for v in fixture.doneFilterVectors {
            XCTAssertEqual(
                BoardSources.availableSupplyIds(
                    source: v.source,
                    supplyTaskIds: v.supplyTaskIds,
                    doneTaskIds: Set(v.doneTaskIds)
                ),
                v.expected,
                v.name
            )
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
