import XCTest
@testable import OYBC

/// `BoardSettingsView.formatDefaultsSummary` — the per-timeframe summary
/// line, incl. the per-timeframe size + centre suffix (docs/POOLS_RECURRING.md
/// §Per-timeframe size + centre, 2026-09-29). iOS twin of web's
/// `formatDefaultsSummary.test.ts`; every string here must match that file
/// verbatim.
final class BoardSettingsSummaryTests: XCTestCase {

    func test_legacyStrings_unchangedWithoutSetup() {
        XCTAssertEqual(BoardSettingsView.formatDefaultsSummary(resolvedCount: 0, poolNames: []), "No default tasks")
        XCTAssertEqual(BoardSettingsView.formatDefaultsSummary(resolvedCount: 0, poolNames: ["Morning Pool"]), "No default tasks")
        XCTAssertEqual(BoardSettingsView.formatDefaultsSummary(resolvedCount: 1, poolNames: []), "1 default task")
        XCTAssertEqual(BoardSettingsView.formatDefaultsSummary(resolvedCount: 2, poolNames: []), "2 default tasks")
        XCTAssertEqual(
            BoardSettingsView.formatDefaultsSummary(resolvedCount: 4, poolNames: ["Morning Pool"]),
            "4 default tasks · from Morning Pool"
        )
        XCTAssertEqual(
            BoardSettingsView.formatDefaultsSummary(resolvedCount: 6, poolNames: ["Morning Pool", "Evening Pool"]),
            "6 default tasks · from 2 pools"
        )
        XCTAssertEqual(
            BoardSettingsView.formatDefaultsSummary(resolvedCount: 4, poolNames: ["Morning Pool"], setup: nil),
            "4 default tasks · from Morning Pool"
        )
    }

    func test_suffix_oddSizeFreeCentre() {
        XCTAssertEqual(
            BoardSettingsView.formatDefaultsSummary(
                resolvedCount: 4, poolNames: ["Morning Pool"],
                setup: CoreBoardSetupDefaults(boardSize: 3, centerType: .free)
            ),
            "4 default tasks · from Morning Pool · 3×3 · free space"
        )
    }

    func test_suffix_oddSizeNoCentre() {
        XCTAssertEqual(
            BoardSettingsView.formatDefaultsSummary(
                resolvedCount: 2, poolNames: [],
                setup: CoreBoardSetupDefaults(boardSize: 5, centerType: .none)
            ),
            "2 default tasks · 5×5 · no free space"
        )
    }

    func test_suffix_evenSizeIsBare_whateverTheCentre() {
        XCTAssertEqual(
            BoardSettingsView.formatDefaultsSummary(
                resolvedCount: 1, poolNames: [],
                setup: CoreBoardSetupDefaults(boardSize: 4, centerType: .none)
            ),
            "1 default task · 4×4"
        )
        XCTAssertEqual(
            BoardSettingsView.formatSetupSuffix(CoreBoardSetupDefaults(boardSize: 4, centerType: .free)),
            "4×4"
        )
    }

    func test_suffix_afterNoDefaultTasks() {
        XCTAssertEqual(
            BoardSettingsView.formatDefaultsSummary(
                resolvedCount: 0, poolNames: ["Ignored"],
                setup: CoreBoardSetupDefaults(boardSize: 3, centerType: .none)
            ),
            "No default tasks · 3×3 · no free space"
        )
    }
}
