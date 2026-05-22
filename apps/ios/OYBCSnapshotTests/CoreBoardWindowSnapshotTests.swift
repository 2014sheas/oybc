import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the two pure-leaf views of the core-board window pager:
///   - `CoreBoardSetupPromptView` — current-window (Set up CTA) and past-window
///     (Backfill CTA) variants.
///   - `CoreBoardWindowBarView` — steady-state bar with prev / label / next /
///     list-button.
///
/// Both views are pure prop-driven leaves with no database dependency, so no
/// GRDB seeding is needed — pass literals directly.
final class CoreBoardWindowSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - CoreBoardSetupPromptView

    /// Current window (isPast: false) — button reads "Set up Today".
    func testSetupPromptCurrentWindow() {
        let view = CoreBoardSetupPromptView(label: "Today", isPast: false, onSetUp: {})
            .frame(width: 393, height: 300)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 300)),
            record: recordMode
        )
    }

    /// Past window (isPast: true) — button reads "Backfill May 18, 2026".
    func testSetupPromptPastWindow() {
        let view = CoreBoardSetupPromptView(label: "May 18, 2026", isPast: true, onSetUp: {})
            .frame(width: 393, height: 300)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 300)),
            record: recordMode
        )
    }

    // MARK: - CoreBoardWindowBarView

    /// Steady-state bar with a weekly window label — exercises label truncation
    /// logic and verifies the four controls (prev, label, next, list) are laid
    /// out correctly at standard iPhone width.
    func testWindowBar() {
        let view = CoreBoardWindowBarView(
            label: "Week of May 18 – 24, 2026",
            onPrev: {},
            onNext: {},
            onOpenList: {}
        )
        .frame(width: 393, height: 56)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 56)),
            record: recordMode
        )
    }
}
