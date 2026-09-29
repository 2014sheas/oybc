import XCTest
@testable import OYBC

/// Cross-platform per-timeframe size + centre resolution enforcement
/// (docs/POOLS_RECURRING.md §Per-timeframe size + centre, 2026-09-29).
///
/// Runs the hand-authored fixture
/// (`packages/shared/tests/fixtures/coreBoardSetupDefaultsVectors.json`)
/// through iOS's `resolveCoreBoardSetupDefaults` / `hasExplicitCoreBoardSetup`
/// in `Helpers/CoreBoardSetupDefaults.swift`. The SAME fixture is exercised on
/// the shared/web side by
/// `packages/shared/tests/algorithms/coreBoardSetupDefaults.test.ts` against
/// `@oybc/shared`'s `coreBoardSetupDefaults.ts`. Both suites passing against
/// the same vectors is what proves the two hand-mirrored implementations agree.
final class CoreBoardSetupDefaultsVectorTests: XCTestCase {

    /// A fixture override pair: a JSON `null` field and an absent field both
    /// decode as nil (Swift's nil covers both — the TS side maps null → absent).
    private struct OverridePair: Decodable {
        let defaultBoardSize: Int?
        let defaultCenterType: String?
    }

    private struct Prefs: Decodable {
        let defaultBoardSize: Int
        let defaultCenterType: String
    }

    private struct Expected: Decodable {
        let boardSize: Int
        let centerType: String
        let hasExplicitSetup: Bool
    }

    private struct Vector: Decodable {
        let name: String
        /// `decodeIfPresent` — an omitted key (undefined) and a JSON null
        /// (null) both land here as nil, which is the Swift `CoreBoardDefault?`.
        let coreDefault: OverridePair?
        let prefs: Prefs
        let expected: Expected
    }

    private struct Fixture: Decodable {
        let vectors: [Vector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CoreBoardSetupDefaultsVectorTests.self).url(
            forResource: "coreBoardSetupDefaultsVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "coreBoardSetupDefaultsVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func toCoreDefault(_ pair: OverridePair?) -> CoreBoardDefault? {
        guard let pair else { return nil }
        let ts = "2026-09-29T00:00:00.000Z"
        return CoreBoardDefault(
            id: "cbd", userId: "u1", timeframe: .daily, corePoolIds: [], coreDefaultTaskIds: [],
            defaultBoardSize: pair.defaultBoardSize.flatMap(DefaultBoardSize.init(rawValue:)),
            defaultCenterType: pair.defaultCenterType.flatMap(DefaultCenterSquareType.init(rawValue:)),
            createdAt: ts, updatedAt: ts
        )
    }

    private func toPrefs(_ p: Prefs) throws -> UserPreferences {
        var prefs = UserPreferences.defaults
        prefs.defaultBoardSize = try XCTUnwrap(DefaultBoardSize(rawValue: p.defaultBoardSize))
        prefs.defaultCenterType = try XCTUnwrap(DefaultCenterSquareType(rawValue: p.defaultCenterType))
        return prefs
    }

    func testFixtureIsNonEmpty() throws {
        XCTAssertFalse(try loadFixture().vectors.isEmpty)
    }

    func testEveryVectorMatchesSharedExpectation() throws {
        let fixture = try loadFixture()
        for v in fixture.vectors {
            let coreDefault = toCoreDefault(v.coreDefault)
            let resolved = resolveCoreBoardSetupDefaults(coreDefault: coreDefault, preferences: try toPrefs(v.prefs))
            XCTAssertEqual(resolved.boardSize, v.expected.boardSize, "[\(v.name)] boardSize")
            XCTAssertEqual(resolved.centerType.rawValue, v.expected.centerType, "[\(v.name)] centerType")
            XCTAssertEqual(hasExplicitCoreBoardSetup(coreDefault), v.expected.hasExplicitSetup, "[\(v.name)] hasExplicitSetup")
        }
    }

    /// The fixture must keep exercising the cases the design calls out.
    func testFixtureCoversTheDesignCases() throws {
        let names = Set(try loadFixture().vectors.map(\.name))
        for required in [
            "no-row-inherits-both",
            "null-row-inherits-both",
            "override-size-only-keeps-prefs-centre",
            "override-centre-only-keeps-prefs-size",
            "override-both",
            "even-size-override-with-free-override-coerces-to-none",
        ] {
            XCTAssertTrue(names.contains(required), "missing vector \(required)")
        }
    }
}
