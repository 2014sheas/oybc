import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `SquareEditTaskSheet` — the board-edit Phase 2 "Edit task"
/// sheet that stages task-field changes in-memory without a DB write.
///
/// Strategy: construct the sheet with a prop-driven `Task` fixture so no
/// `AppDatabase.shared` access or `@EnvironmentObject` is needed. The sheet is
/// a `NavigationStack` so snapshots capture the full chrome.
///
/// Variants covered:
///   - Normal task (Simple chip selected) — light + dark
///   - Counting task (Counting chip selected, fields pre-filled) — light + dark
///   - Compound task (Compound chip selected, hint card visible) — light
///
/// Height: 680pt for normal/compound (short), 780pt for counting (extra fields).
final class SquareEditTaskSheetSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Normal task

    func testNormalLight() {
        assertSnapshot(
            of: makeSheet(task: normalTask()),
            as: .image(layout: .fixed(width: 393, height: 680)),
            record: recordMode
        )
    }

    func testNormalDark() {
        assertSnapshot(
            of: makeSheet(task: normalTask()),
            as: .image(
                layout: .fixed(width: 393, height: 680),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Counting task

    func testCountingLight() {
        assertSnapshot(
            of: makeSheet(task: countingTask()),
            as: .image(layout: .fixed(width: 393, height: 780)),
            record: recordMode
        )
    }

    func testCountingDark() {
        assertSnapshot(
            of: makeSheet(task: countingTask()),
            as: .image(
                layout: .fixed(width: 393, height: 780),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Compound task

    func testCompoundLight() {
        assertSnapshot(
            of: makeSheet(task: compoundTask()),
            as: .image(layout: .fixed(width: 393, height: 680)),
            record: recordMode
        )
    }

    // MARK: - Task fixtures

    /// Plain normal task — type chip shows "Simple" selected.
    private func normalTask() -> Task {
        SnapshotFixtures.makeTask(
            id: "sett-normal",
            title: "Morning workout",
            type: .normal
        )
    }

    /// Counting task with pre-filled action/unit/goal — counting fields visible.
    private func countingTask() -> Task {
        SnapshotFixtures.makeTask(
            id: "sett-counting",
            title: "Run daily",
            type: .counting,
            action: "Run",
            unit: "km",
            maxCount: 5
        )
    }

    /// Compound task — compound hint card visible, subtasks read-only.
    private func compoundTask() -> Task {
        SnapshotFixtures.makeTask(
            id: "sett-compound",
            title: "Morning routine",
            type: .compound
        )
    }

    // MARK: - View builder

    private func makeSheet(task: Task) -> some View {
        SquareEditTaskSheet(
            task: task,
            onDone: { _ in },
            onCancel: {}
        )
    }
}
