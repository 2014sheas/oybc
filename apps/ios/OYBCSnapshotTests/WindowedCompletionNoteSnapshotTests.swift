import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Windowed Completion one-time upgrade note
/// (docs/WINDOWED_COMPLETION.md §What changes visibly at upgrade). Renders the
/// deterministic leaf `WindowedCompletionNoteCard` (no `@AppStorage`
/// persistence) in both light and dark so the gold surface + `risoInkStatic`
/// contract is baselined. New baselines only — no existing snapshot changes.
final class WindowedCompletionNoteSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private var card: some View {
        WindowedCompletionNoteCard(onDismiss: {})
            .padding(20)
            .frame(width: 393)
            .background(Color.risoPaper)
    }

    func testNoteLight() {
        assertSnapshot(
            of: card,
            as: .image(layout: .fixed(width: 393, height: 140)),
            record: recordMode
        )
    }

    func testNoteDark() {
        assertSnapshot(
            of: card,
            as: .image(
                layout: .fixed(width: 393, height: 140),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }
}
