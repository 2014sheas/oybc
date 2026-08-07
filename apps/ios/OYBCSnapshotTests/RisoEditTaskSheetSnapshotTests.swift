import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for the Riso-reskinned `EditTaskSheet`.
///
/// Strategy: render the REAL `EditTaskSheet(task:availableBoards:availableTemplates:
/// onSubmit:onCancel:)` directly with fixture tasks so the snapshots
/// capture the actual production view — not a hand-mirrored copy.
///
/// Variants (light + dark each):
///   1. Normal task — Details + Time-window cards only.
///   2. Counting task — Details + Counting (action/goal/unit) + Time-window.
///   3. Achievement watching a specific board — trigger + board picker seeded.
///   4. Achievement watching a recurring template — template picker + required count.
///   5. Compound task — Details + compound hint + Time-window.
///
/// Determinism: all fixture tasks have `timeframe = nil` so the Date-pickers
/// remain hidden and no `Date()` value leaks into the snapshot. Achievement
/// variants also omit a timeframe. This sidesteps the calendar-rollover
/// flakiness documented in `reference_snapshot_date_dependent.md`.
final class RisoEditTaskSheetSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - 1. Normal task

    func testNormalLight() {
        let view = makeSheet(task: normalTask())
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 560)),
            record: recordMode
        )
    }

    func testNormalDark() {
        let view = makeSheet(task: normalTask())
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 560),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - 2. Counting task

    func testCountingLight() {
        let view = makeSheet(task: countingTask())
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    func testCountingDark() {
        let view = makeSheet(task: countingTask())
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 700),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - 3. Achievement — specific board

    func testAchievementBoardLight() {
        let boards = [
            SnapshotFixtures.makeBoard(id: "board-1", name: "April Reading Sprint"),
            SnapshotFixtures.makeBoard(id: "board-2", name: "Monthly Wellness"),
        ]
        let view = makeSheet(task: achievementBoardTask(boardId: "board-1"), boards: boards)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    func testAchievementBoardDark() {
        let boards = [
            SnapshotFixtures.makeBoard(id: "board-1", name: "April Reading Sprint"),
            SnapshotFixtures.makeBoard(id: "board-2", name: "Monthly Wellness"),
        ]
        let view = makeSheet(task: achievementBoardTask(boardId: "board-1"), boards: boards)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 700),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - 4. Achievement — recurring template

    func testAchievementTemplateLight() {
        let templates = [
            SnapshotFixtures.makeRecurringTemplate(id: "tpl-1", name: "Weekly Workout"),
            SnapshotFixtures.makeRecurringTemplate(id: "tpl-2", name: "Monthly Reading"),
        ]
        let view = makeSheet(
            task: achievementTemplateTask(templateId: "tpl-1", requiredCount: 3),
            templates: templates
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 760)),
            record: recordMode
        )
    }

    func testAchievementTemplateDark() {
        let templates = [
            SnapshotFixtures.makeRecurringTemplate(id: "tpl-1", name: "Weekly Workout"),
            SnapshotFixtures.makeRecurringTemplate(id: "tpl-2", name: "Monthly Reading"),
        ]
        let view = makeSheet(
            task: achievementTemplateTask(templateId: "tpl-1", requiredCount: 3),
            templates: templates
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 760),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - 5. Compound task

    func testCompoundLight() {
        let view = makeSheet(task: compoundTask())
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 620)),
            record: recordMode
        )
    }

    func testCompoundDark() {
        let view = makeSheet(task: compoundTask())
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 620),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - View builder

    /// Wraps a real `EditTaskSheet` in a plain `Color.risoPaper` container
    /// so the toolbar chrome renders as part of the snapshot. The sheet uses
    /// a `NavigationStack` internally, which provides the toolbar.
    private func makeSheet(
        task: Task,
        boards: [Board] = [],
        templates: [RecurringBoardTemplate] = []
    ) -> some View {
        EditTaskSheet(
            task: task,
            availableBoards: boards,
            availableTemplates: templates,
            onSubmit: { _ in },
            onCancel: {}
        )
    }

    // MARK: - Fixture tasks

    /// Normal task — no type-specific sections, no timeframe (pickers hidden).
    private func normalTask() -> Task {
        SnapshotFixtures.makeTask(
            id: "et-normal",
            title: "Meditate for 10 minutes",
            type: .normal
        )
    }

    /// Counting task — seeded with action/goal/unit, no timeframe.
    private func countingTask() -> Task {
        SnapshotFixtures.makeTask(
            id: "et-counting",
            title: "Run 5 km",
            type: .counting,
            action: "Run",
            unit: "km",
            maxCount: 5
        )
    }

    /// Achievement task watching a specific board. `referencedBoardId` is
    /// set via direct mutation after construction because `SnapshotFixtures.makeTask`
    /// doesn't expose achievement fields — those are set on the model directly
    /// since `Task` is a value type with `var` properties.
    private func achievementBoardTask(boardId: String) -> Task {
        var task = Task(
            id: "et-achievement-board",
            userId: SnapshotFixtures.userId,
            title: "GREENLOG the reading sprint",
            type: .achievement,
            referencedBoardId: boardId,
            achievementTrigger: .greenlog,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: SnapshotFixtures.fixedTimestamp,
            updatedAt: SnapshotFixtures.fixedTimestamp,
            version: 1,
            isDeleted: false
        )
        // timeframe is nil by default — DatePickers stay hidden for determinism.
        return task
    }

    /// Achievement task watching a recurring template with a required count.
    private func achievementTemplateTask(templateId: String, requiredCount: Int) -> Task {
        Task(
            id: "et-achievement-template",
            userId: SnapshotFixtures.userId,
            title: "Hit the weekly goal 3 times",
            type: .achievement,
            referencedTemplateId: templateId,
            achievementTrigger: .greenlog,
            requiredCount: requiredCount,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: SnapshotFixtures.fixedTimestamp,
            updatedAt: SnapshotFixtures.fixedTimestamp,
            version: 1,
            isDeleted: false
        )
    }

    /// Compound task — shows the hint card explaining subtasks are wizard-edited.
    private func compoundTask() -> Task {
        SnapshotFixtures.makeTask(
            id: "et-compound",
            title: "Daily wellness routine",
            type: .compound,
            operatorType: .and
        )
    }
}
