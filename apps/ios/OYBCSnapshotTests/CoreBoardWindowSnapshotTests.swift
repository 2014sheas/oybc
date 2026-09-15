import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `CoreBoardSetupPromptView` — current-window
/// (Set up CTA) and past-window (Backfill CTA) variants. (The old
/// `CoreBoardWindowBarView` was retired by the core-board surface
/// rework — its replacement chrome is covered in
/// `RisoCoreChromeSnapshotTests`.)
///
/// A pure prop-driven leaf with no database dependency, so no GRDB
/// seeding is needed — pass literals directly.
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

}
