import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Riso-reskinned Edit Board flow.
///
/// Strategy: render the REAL `BoardSetupFormView` in `.editActive` mode
/// directly — not a hand-mirrored copy — so the tests fail if the
/// production views regress.
///
/// `EditBoardSheet` depends on `@EnvironmentObject AuthService` and fires
/// async DB reads in `.onAppear`. Both make snapshot wiring non-trivial, so
/// we snapshot `BoardSetupFormView` directly (in a paper ScrollView) to get
/// deterministic control over each field state, following the same strategy
/// as the pre-existing `EditBoardSheetSnapshotTests`.
///
/// Determinism rules:
///   - Fixed dates (`Date(timeIntervalSince1970: …)`) — never `Date()`.
///   - `weekStartDay: "monday"` throughout.
///   - For non-custom timeframes the date note label is computed from the
///     current calendar date at test time (not pinned). The note is a
///     supporting detail; the structural chrome (name field, RisoSegmented
///     pickers, center section) is layout-stable and is what these tests
///     guard. See `reference_snapshot_date_dependent.md` for context.
final class RisoEditBoardSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // Fixed pinned dates used throughout — 2026-04-01 and 2026-04-30.
    private static let fixedStart = Date(timeIntervalSince1970: 1_743_465_600) // 2026-04-01 UTC
    private static let fixedEnd   = Date(timeIntervalSince1970: 1_746_057_600) // 2026-04-30 UTC

    // MARK: - Form: monthly timeframe, free center (light)

    func testFormMonthlyFreeLight() {
        let view = makeForm(timeframe: .monthly, centerType: .free)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 620)),
            record: recordMode
        )
    }

    // MARK: - Form: monthly timeframe, free center (dark)

    func testFormMonthlyFreeDark() {
        let view = makeForm(timeframe: .monthly, centerType: .free)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 620),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Form: weekly timeframe, none center (light)

    func testFormWeeklyNoneLight() {
        let view = makeForm(timeframe: .weekly, centerType: .none)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 620)),
            record: recordMode
        )
    }

    // MARK: - Form: weekly timeframe, none center (dark)

    func testFormWeeklyNoneDark() {
        let view = makeForm(timeframe: .weekly, centerType: .none)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 620),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Form: custom dates, customFree center (light)

    func testFormCustomDatesCustomFreeLight() {
        let view = makeForm(
            timeframe: .custom,
            centerType: .customFree,
            centerCustomName: "Wild Card"
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 750)),
            record: recordMode
        )
    }

    // MARK: - Form: custom dates, customFree center (dark)

    func testFormCustomDatesCustomFreeDark() {
        let view = makeForm(
            timeframe: .custom,
            centerType: .customFree,
            centerCustomName: "Wild Card"
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 750),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - View builders

    /// Builds a `BoardSetupFormView` in `.editActive` mode wrapped in a
    /// paper-background `ScrollView` so sections render outside a `Form`.
    private func makeForm(
        name: String = "Spring Goals",
        timeframe: Timeframe = .monthly,
        centerType: CenterSquareType = .free,
        centerCustomName: String = "",
        chosenCenterDisabled: Bool = false
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BoardSetupFormView(
                    name: .constant(name),
                    timeframe: .constant(timeframe),
                    customStartDate: .constant(Self.fixedStart),
                    customEndDate: .constant(Self.fixedEnd),
                    centerType: .constant(centerType),
                    centerCustomName: .constant(centerCustomName),
                    weekStartDay: "monday",
                    chosenCenterDisabled: chosenCenterDisabled
                )
            }
            .padding(16)
        }
        .background(Color.risoPaper.ignoresSafeArea())
    }

}
