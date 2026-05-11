import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Phase 6.3 — Snapshot coverage for the `AchievementSquareConfigSheet`
/// SwiftUI modal. The sheet has three modes (aggregate / specific-
/// board / recurring-template) plus an off-state when the toggle is
/// disabled; one snapshot per primary surface plus a paused-template
/// warning variant.
///
/// Cycle-detection error rendering is NOT covered here because it
/// requires triggering a Save with a constructed cycle in state —
/// the `cyclePath` field is local to `handleSave()` and isn't
/// reachable from a fixture. The cycle-detection algorithm itself
/// is covered by `CycleDetectionTests.swift` (11 unit tests).
final class AchievementSquareConfigSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Fixtures

    /// Sample board used as the "parent" board for the cell being
    /// configured. Window dates pin to April 2026 so the template
    /// in-window calculation is deterministic.
    private var parentBoard: Board {
        SnapshotFixtures.makeBoard(
            id: "board-parent",
            name: "Monthly Goals",
            startDate: "2026-04-01T00:00:00.000Z",
            endDate: "2026-04-30T23:59:59.000Z"
        )
    }

    /// A peer board the user could pick in specific-board mode. Status
    /// COMPLETED so the picker row shows the "completed" meta label.
    private var peerBoard: Board {
        SnapshotFixtures.makeBoard(
            id: "board-peer",
            name: "Daily Wellness",
            timeframe: .daily,
            status: .completed
        )
    }

    /// Workspace boards list — parent + peer + a template-spawned board
    /// inside the parent's window. The template-mode snapshot uses the
    /// spawn to show a non-empty in-window count.
    private var allBoards: [Board] {
        [
            parentBoard,
            peerBoard,
            SnapshotFixtures.makeBoard(
                id: "board-spawn-1",
                name: "Leg Day · April 8",
                timeframe: .weekly,
                status: .completed,
                startDate: "2026-04-08T00:00:00.000Z",
                endDate: "2026-04-14T23:59:59.000Z",
                spawnedFromTemplateId: "tpl-leg-day"
            )
        ]
    }

    /// Two templates: one active (Leg Day) and one paused (Weekly
    /// Reading). The paused-template variant exercises the inline
    /// warning row.
    private var allTemplates: [RecurringBoardTemplate] {
        [
            SnapshotFixtures.makeRecurringTemplate(
                id: "tpl-leg-day",
                name: "Leg Day",
                timeframe: .weekly,
                isActive: true
            ),
            SnapshotFixtures.makeRecurringTemplate(
                id: "tpl-reading",
                name: "Weekly Reading",
                timeframe: .weekly,
                isActive: false
            )
        ]
    }

    /// The cell being edited — a NORMAL task currently NOT an
    /// achievement square. Specific-test fixtures override the
    /// achievement fields below.
    private func boardTask(
        isAchievementSquare: Bool = true,
        referencedBoardId: String? = nil,
        referencedTemplateId: String? = nil
    ) -> BoardTask {
        SnapshotFixtures.makeBoardTask(
            id: "bt-1",
            boardId: "board-parent",
            taskId: "task-1",
            row: 0,
            col: 0,
            isAchievementSquare: isAchievementSquare,
            achievementType: .fullCompletion,
            achievementCount: 5,
            achievementTimeframe: .weekly,
            referencedBoardId: referencedBoardId,
            referencedTemplateId: referencedTemplateId
        )
    }

    // MARK: - Snapshots

    /// Aggregate-mode default — toggle ON, no reference fields set.
    /// Form shows the count Stepper + timeframe Picker + type Picker.
    func testAggregateMode() {
        let view = AchievementSquareConfigSheet(
            boardTask: boardTask(),
            parentBoard: parentBoard,
            allBoards: allBoards,
            allBoardTasks: [],
            allTemplates: allTemplates,
            taskTitle: "Read 30 minutes",
            onSave: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    /// Specific-board mode with the peer board pre-picked. Picker list
    /// is visible with the selection indicator on Daily Wellness.
    func testSpecificBoardMode_BoardPicked() {
        let view = AchievementSquareConfigSheet(
            boardTask: boardTask(referencedBoardId: "board-peer"),
            parentBoard: parentBoard,
            allBoards: allBoards,
            allBoardTasks: [],
            allTemplates: allTemplates,
            taskTitle: "Q1 launch goals",
            onSave: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    /// Recurring-template mode with Leg Day pre-picked. Template has
    /// one spawn inside the parent's window (board-spawn-1), so no
    /// empty-window warning fires; paused-template warning is absent
    /// (Leg Day isActive=true).
    func testRecurringTemplateMode_TemplatePicked() {
        let view = AchievementSquareConfigSheet(
            boardTask: boardTask(referencedTemplateId: "tpl-leg-day"),
            parentBoard: parentBoard,
            allBoards: allBoards,
            allBoardTasks: [],
            allTemplates: allTemplates,
            taskTitle: "Monthly fitness",
            onSave: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 800)),
            record: recordMode
        )
    }

    /// Paused-template warning surface — picks the inactive Weekly
    /// Reading template so the inline "this template is paused"
    /// warning row renders. Also exercises the empty-window warning
    /// because no Weekly Reading spawns exist in the workspace.
    func testRecurringTemplateMode_PausedTemplateWarning() {
        let view = AchievementSquareConfigSheet(
            boardTask: boardTask(referencedTemplateId: "tpl-reading"),
            parentBoard: parentBoard,
            allBoards: allBoards,
            allBoardTasks: [],
            allTemplates: allTemplates,
            taskTitle: "Reading goals",
            onSave: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 900)),
            record: recordMode
        )
    }

    /// Toggle-OFF state — the "Treat this cell as an achievement
    /// square" toggle is off; mode selector + sub-controls are hidden.
    /// Saving from this state clears all achievement fields.
    func testToggleOff() {
        let view = AchievementSquareConfigSheet(
            boardTask: boardTask(isAchievementSquare: false),
            parentBoard: parentBoard,
            allBoards: allBoards,
            allBoardTasks: [],
            allTemplates: allTemplates,
            taskTitle: "Plain task",
            onSave: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 500)),
            record: recordMode
        )
    }
}
