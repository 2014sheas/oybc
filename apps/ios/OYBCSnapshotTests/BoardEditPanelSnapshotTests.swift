import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the squares-only `BoardEditPanel` (Board Edit
/// redesign slice 2, T3 — docs/BOARD_EDIT_REDESIGN.md). Slice 2 retired the
/// size chip, `BoardSetupFormView`, the staged REPEATS section, and Archive
/// from this panel — they moved to the "…" menu's own sheets/alerts (see
/// `BoardActionsSnapshotTests`, which also carries the two REPEATS variants
/// that used to be recorded here as `testPanelRepeat*`).
///
/// Strategy: render the leaf view directly with constant bindings so no
/// `AppDatabase.shared` access or `@EnvironmentObject` wiring is needed.
/// Four scenarios are covered:
///   - Clean/light  — the center-toggle binding matches the board's stored value (Save disabled)
///   - Clean/dark   — same in dark mode
///   - Dirty/light  — `centerType` differs from `board.centerSquareType` (edit-count and Save pill active)
///   - Saving/light — `isSaving: true` (pill shows "Saving…", Save still disabled)
final class BoardEditPanelSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Tests

    func testPanelMonthlyCleanLight() {
        assertSnapshot(
            of: makePanel(),
            as: .image(layout: .fixed(width: 393, height: 1000)),
            record: recordMode
        )
    }

    func testPanelMonthlyCleanDark() {
        assertSnapshot(
            of: makePanel(),
            as: .image(
                layout: .fixed(width: 393, height: 1000),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    /// Dirty state: `centerType` binding differs from `board.centerSquareType`
    /// (the panel's ONE remaining metadata field, per D5).
    /// Expect: edit counter shows "1 edit", Save pill is gold and enabled.
    func testPanelDirtyLight() {
        assertSnapshot(
            of: makePanel(centerType: .none),
            as: .image(layout: .fixed(width: 393, height: 1000)),
            record: recordMode
        )
    }

    /// Saving state: `isSaving: true` forces pill text to "Saving…".
    func testPanelSavingLight() {
        assertSnapshot(
            of: makePanel(centerType: .none, isSaving: true),
            as: .image(layout: .fixed(width: 393, height: 1000)),
            record: recordMode
        )
    }

    // MARK: - View builder

    /// Builds a `BoardEditPanel` with constant bindings. All task / boardTask data is
    /// hardcoded so the same pixel output is produced regardless of DB state.
    ///
    /// - Parameters:
    ///   - centerType: Value for the draft `centerType` binding (defaults to
    ///     `board.centerSquareType` → clean state).
    ///   - isSaving: Whether to render the saving indicator state.
    private func makePanel(
        centerType: CenterSquareType = .free,
        isSaving: Bool = false
    ) -> some View {
        // Board fixture — 3×3 monthly active board, FREE center.
        let board = SnapshotFixtures.makeBoard(
            id: "ep-board-1",
            name: "Spring Goals",
            boardSize: 3
        )

        // Task fixtures — 9 tasks for a fully-populated 3×3 grid.
        // et-t2 is completed (green fill); et-bt5 is the center (gold fill).
        let tasks: [Task] = [
            SnapshotFixtures.makeTask(id: "ep-t1", title: "Morning workout",      type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t2", title: "Cook a meal",          type: .normal, isCompleted: true),
            SnapshotFixtures.makeTask(id: "ep-t3", title: "Call a friend",        type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t4", title: "Read 50 pages",        type: .counting,
                                      action: "Read", unit: "pages", maxCount: 50),
            SnapshotFixtures.makeTask(id: "ep-t5", title: "Meditate 10 min",      type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t6", title: "Write in journal",     type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t7", title: "Take a walk",          type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t8", title: "Stretch",              type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t9", title: "Drink 8 glasses",      type: .counting,
                                      action: "Drink", unit: "glasses", maxCount: 8),
        ]

        let boardTasks: [BoardTask] = [
            SnapshotFixtures.makeBoardTask(id: "ep-bt1", boardId: "ep-board-1", taskId: "ep-t1", row: 0, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ep-bt2", boardId: "ep-board-1", taskId: "ep-t2", row: 0, col: 1),
            SnapshotFixtures.makeBoardTask(id: "ep-bt3", boardId: "ep-board-1", taskId: "ep-t3", row: 0, col: 2),
            SnapshotFixtures.makeBoardTask(id: "ep-bt4", boardId: "ep-board-1", taskId: "ep-t4", row: 1, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ep-bt5", boardId: "ep-board-1", taskId: "ep-t5", row: 1, col: 1, isCenter: true),
            SnapshotFixtures.makeBoardTask(id: "ep-bt6", boardId: "ep-board-1", taskId: "ep-t6", row: 1, col: 2),
            SnapshotFixtures.makeBoardTask(id: "ep-bt7", boardId: "ep-board-1", taskId: "ep-t7", row: 2, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ep-bt8", boardId: "ep-board-1", taskId: "ep-t8", row: 2, col: 1),
            SnapshotFixtures.makeBoardTask(id: "ep-bt9", boardId: "ep-board-1", taskId: "ep-t9", row: 2, col: 2),
        ]

        let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        return BoardEditPanel(
            board: board,
            boardTasks: boardTasks,
            taskMap: taskMap,
            centerType: .constant(centerType),
            subMode: .constant(.editTasks),
            isSaving: isSaving,
            onSave: {},
            onCancelConfirmed: {}
        )
    }
}
