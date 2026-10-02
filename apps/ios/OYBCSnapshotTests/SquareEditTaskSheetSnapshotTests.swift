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

    // MARK: - Compound editing (Board Edit "Edit task…")

    /// A Simple task: the type picker offers Simple / Counting / Compound.
    func testNormalThreeSegmentPickerLight() {
        assertSnapshot(
            of: makeSheet(task: normalTask()),
            as: .image(layout: .fixed(width: 393, height: 480)),
            record: recordMode
        )
    }

    /// Compound picked on a Simple task: the editor opens with the default
    /// rule and no sub-tasks (Done is blocked until two are added).
    func testConvertedCompoundEditorLight() {
        assertSnapshot(
            of: SquareEditTaskSheet(
                task: normalTask(), startingType: .compound, onDone: { _ in }, onCancel: {}
            ),
            as: .image(layout: .fixed(width: 393, height: 900)),
            record: recordMode
        )
    }

    /// An existing compound: type fixed (badge, no picker), editor open with
    /// its sub-tasks.
    func testExistingCompoundFixedTypeEditorLight() {
        let kids = [
            SnapshotFixtures.makeTask(id: "sett-kid-1", title: "Stretch", type: .normal),
            SnapshotFixtures.makeTask(id: "sett-kid-2", title: "Hydrate", type: .normal),
        ]
        assertSnapshot(
            of: SquareEditTaskSheet(
                task: compoundTask(), compoundChildren: kids, onDone: { _ in }, onCancel: {}
            ),
            as: .image(layout: .fixed(width: 393, height: 900)),
            record: recordMode
        )
    }

    /// A linked counter: type fixed (no picker), title + counting fields only.
    func testLinkedCounterFixedTypeLight() {
        var task = countingTask()
        task.sharedCounterId = "sett-shared"
        assertSnapshot(
            of: makeSheet(task: task),
            as: .image(layout: .fixed(width: 393, height: 780)),
            record: recordMode
        )
    }

    // MARK: - Achievement task

    /// P0 regression: an achievement opens with its real type badge, no
    /// Simple / Counting picker, and the read-only achievement notice.
    func testAchievementLight() {
        assertSnapshot(
            of: makeSheet(task: achievementTask()),
            as: .image(layout: .fixed(width: 393, height: 680)),
            record: recordMode
        )
    }

    // MARK: - Task fixtures

    /// Achievement task — type is immutable here, title only.
    private func achievementTask() -> Task {
        SnapshotFixtures.makeTask(
            id: "sett-achievement",
            title: "Bingo on June",
            type: .achievement
        )
    }

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
