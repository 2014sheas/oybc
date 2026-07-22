import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `RisoQuickAddRowView`'s OPTIONAL library-poll
/// dropdown (owner decision 2026-07-21) — the shared quick-add row used by
/// both `PoolEditSheetView` and `BoardWizardTasksStepView`.
///
/// Renders the **real** view via its `seedText:` initialiser (mirrors
/// `RisoCompoundFieldsView(seed:)`'s testability pattern), which pre-fills
/// the field without needing to simulate keyboard focus — the dropdown is
/// purely text-driven (`showLibraryDropdown` derives from `libraryMatches`,
/// which derives from the trimmed field text), so a seeded non-empty text
/// renders the populated-dropdown state deterministically.
///
/// Width: 393pt (iPhone 16).
final class RisoQuickAddRowSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func libraryTasks() -> [Task] {
        [
            SnapshotFixtures.makeTask(id: "t1", title: "Meditate 10 min", type: .normal),
            SnapshotFixtures.makeTask(id: "t2", title: "Meditate before bed", type: .normal),
            SnapshotFixtures.makeTask(id: "t3", title: "Morning meditation walk", type: .counting, action: "Walk", unit: "min", maxCount: 20),
        ]
    }

    private func row(seedText: String) -> some View {
        ZStack {
            RisoPaperBackground()
            RisoQuickAddRowView(
                userId: SnapshotFixtures.userId,
                defaultStartDate: nil,
                defaultEndDate: nil,
                onTaskCreated: { _, _, _ in },
                onPendingCreated: nil,
                onLibraryReloadRequested: {},
                libraryTasks: libraryTasks(),
                selectedIds: [],
                onExistingTaskPicked: { _ in },
                seedText: seedText
            )
            .padding(Riso.gutter)
        }
    }

    // MARK: - Populated dropdown (2 of the 3 fixtures match "medit")

    func testDropdownPopulatedLight() {
        assertSnapshot(
            of: row(seedText: "medit"),
            as: .image(layout: .fixed(width: 393, height: 220), traits: .init(userInterfaceStyle: .light)),
            record: recordMode
        )
    }

    func testDropdownPopulatedDark() {
        assertSnapshot(
            of: row(seedText: "medit"),
            as: .image(layout: .fixed(width: 393, height: 220), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }
}
