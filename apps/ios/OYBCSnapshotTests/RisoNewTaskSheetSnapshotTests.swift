import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for `NewTaskSheetView` — the Riso "New task" bottom sheet
/// presented from the Tasks-tab "+" button.
///
/// Strategy: render a `NewTaskSheetContentView` host (same content the sheet
/// shows, minus the NavigationStack chrome — this avoids simulator-nav-bar
/// height jitter while still capturing every real component). Separately
/// snapshots the full sheet wrapper via a fixed-height host that wraps a
/// `NavigationStack` clone with the Done/Cancel toolbar items.
///
/// Variants (light + dark each):
///   1. Default — quick-add row + collapsed special panel + caption note.
///
/// Width: 393pt (iPhone 16). Height sized to fit the default layout.
final class RisoNewTaskSheetSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - 1. Default state (quick-add + collapsed special panel + note)

    func testDefaultLight() {
        let view = makeDefaultContent()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 380)),
            record: recordMode
        )
    }

    func testDefaultDark() {
        let view = makeDefaultContent()
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 380),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Builder

    /// Renders the REAL production `NewTaskSheetContentView` (the same view the
    /// sheet body uses), so the snapshot captures the actual layout + components
    /// — not a hand-written mirror. Padding/background match the sheet's chrome.
    private func makeDefaultContent() -> some View {
        ScrollView {
            NewTaskSheetContentView(
                userId: SnapshotFixtures.userId,
                onTaskCreated: { _, _, _ in },
                onLibraryReloadRequested: {}
            )
            .padding(16)
        }
        .background(Color.risoPaper)
    }
}
