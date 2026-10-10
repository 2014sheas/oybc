import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `RisoQuickAddRowView`'s OPTIONAL library-poll
/// dropdown (owner decision 2026-07-21) — the shared quick-add row used by
/// both `PoolEditorBodyView` and `BoardWizardTasksStepView`.
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

    // MARK: - Shared counter match rows (docs/SHARED_COUNTER_SETTINGS.md §2)

    /// A board-context quick-add row over one counter root.
    private func counterRow(root: Task, seedText: String) -> some View {
        ZStack {
            RisoPaperBackground()
            RisoQuickAddRowView(
                userId: SnapshotFixtures.userId,
                defaultTimeframe: .weekly,
                defaultStartDate: nil,
                defaultEndDate: nil,
                onTaskCreated: { _, _, _ in },
                onPendingCreated: { _ in },
                onLibraryReloadRequested: {},
                libraryTasks: [root],
                selectedIds: [],
                onExistingTaskPicked: { _ in },
                seedText: seedText
            )
            .padding(Riso.gutter)
        }
    }

    private var weeklyDefaultRoot: Task {
        SnapshotFixtures.makeTask(
            id: "c1", title: "Read 12 books", type: .counting, action: "Read", unit: "books", maxCount: 12,
            isCounter: true, timeframeGoals: CounterTimeframeGoals(weekly: 2), counterName: "Books"
        )
    }

    private var ownGoalRoot: Task {
        SnapshotFixtures.makeTask(
            id: "c2", title: "Read 12 books", type: .counting, action: "Read", unit: "books", maxCount: 12,
            isCounter: true, counterName: "Books"
        )
    }

    private var goalLessRoot: Task {
        SnapshotFixtures.makeTask(
            id: "c3", title: "Read books", type: .counting, action: "Read", unit: "books", isCounter: true
        )
    }

    private func assertCounterRow(_ root: Task, dark: Bool, name: String = #function) {
        assertSnapshot(
            of: counterRow(root: root, seedText: "book"),
            as: .image(layout: .fixed(width: 393, height: 160), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
            record: recordMode, testName: name
        )
    }

    /// "Weekly · 2 books" — the root's weekly default on a weekly board.
    func testCounterRowWeeklyDefaultLight() { assertCounterRow(weeklyDefaultRoot, dark: false) }
    func testCounterRowWeeklyDefaultDark() { assertCounterRow(weeklyDefaultRoot, dark: true) }

    /// "12 books" — no default for the board, the root's own goal, no prefix.
    func testCounterRowOwnGoalLight() { assertCounterRow(ownGoalRoot, dark: false) }
    func testCounterRowOwnGoalDark() { assertCounterRow(ownGoalRoot, dark: true) }

    /// A goal-less root with no default: an inline Goal entry, the plus dimmed.
    func testCounterRowGoalEntryLight() { assertCounterRow(goalLessRoot, dark: false) }
    func testCounterRowGoalEntryDark() { assertCounterRow(goalLessRoot, dark: true) }
}
