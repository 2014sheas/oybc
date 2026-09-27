import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the squares-only `BoardEditPanel` (Board Edit
/// redesign slice 3, T5 — docs/BOARD_EDIT_REDESIGN.md). Slice 3 (D7)
/// retired the Edit-tasks ⇄ Rearrange sub-mode toggle — the panel now
/// renders ONE grid (`SquaresEditGrid`), fed `cells: [SquareEditCellData]`.
///
/// Strategy: render the leaf view directly with hardcoded props so no
/// `AppDatabase.shared` access or `@EnvironmentObject` wiring is needed.
/// Four scenarios are covered:
///   - Clean/light  — editCount 0 (Save disabled, Shuffle enabled)
///   - Clean/dark   — same in dark mode
///   - Dirty/light  — editCount > 0 (Save pill active)
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

    /// Dirty state: a staged replacement on cell (0,0) — expect the gold
    /// pencil chip on that square, "1 edit", and an enabled Save pill.
    func testPanelDirtyLight() {
        assertSnapshot(
            of: makePanel(editCount: 1, replaceFirstCell: true),
            as: .image(layout: .fixed(width: 393, height: 1000)),
            record: recordMode
        )
    }

    /// Saving state: `isSaving: true` forces pill text to "Saving…".
    func testPanelSavingLight() {
        assertSnapshot(
            of: makePanel(editCount: 1, replaceFirstCell: true, isSaving: true),
            as: .image(layout: .fixed(width: 393, height: 1000)),
            record: recordMode
        )
    }

    // MARK: - View builder

    /// Builds a `BoardEditPanel` for a fully-populated 3×3 board, FREE center.
    ///
    /// - Parameters:
    ///   - editCount: The staged edit count to display.
    ///   - replaceFirstCell: When true, cell (0,0) is marked dirty (a staged
    ///     replacement) so the pencil chip is visible.
    ///   - isSaving: Whether to render the saving indicator state.
    private func makePanel(
        editCount: Int = 0,
        replaceFirstCell: Bool = false,
        isSaving: Bool = false
    ) -> some View {
        let board = SnapshotFixtures.makeBoard(id: "ep-board-1", name: "Spring Goals", boardSize: 3)

        let tasks: [Task] = [
            SnapshotFixtures.makeTask(id: "ep-t1", title: "Morning workout",      type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t2", title: "Cook a meal",          type: .normal, isCompleted: true),
            SnapshotFixtures.makeTask(id: "ep-t3", title: "Call a friend",        type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t4", title: "Read 50 pages",        type: .counting,
                                      action: "Read", unit: "pages", maxCount: 50),
            SnapshotFixtures.makeTask(id: "ep-t6", title: "Write in journal",     type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t7", title: "Take a walk",          type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t8", title: "Stretch",              type: .normal),
            SnapshotFixtures.makeTask(id: "ep-t9", title: "Drink 8 glasses",      type: .counting,
                                      action: "Drink", unit: "glasses", maxCount: 8),
        ]

        // (1,1) is the FREE center — no BoardTask there.
        let boardTasks: [BoardTask] = [
            SnapshotFixtures.makeBoardTask(id: "ep-bt1", boardId: "ep-board-1", taskId: "ep-t1", row: 0, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ep-bt2", boardId: "ep-board-1", taskId: "ep-t2", row: 0, col: 1),
            SnapshotFixtures.makeBoardTask(id: "ep-bt3", boardId: "ep-board-1", taskId: "ep-t3", row: 0, col: 2),
            SnapshotFixtures.makeBoardTask(id: "ep-bt4", boardId: "ep-board-1", taskId: "ep-t4", row: 1, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ep-bt6", boardId: "ep-board-1", taskId: "ep-t6", row: 1, col: 2),
            SnapshotFixtures.makeBoardTask(id: "ep-bt7", boardId: "ep-board-1", taskId: "ep-t7", row: 2, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ep-bt8", boardId: "ep-board-1", taskId: "ep-t8", row: 2, col: 1),
            SnapshotFixtures.makeBoardTask(id: "ep-bt9", boardId: "ep-board-1", taskId: "ep-t9", row: 2, col: 2),
        ]

        var draft = SnapshotFixtures.makeSquaresDraft(from: boardTasks)
        if replaceFirstCell, var cell = draft["0-0"] {
            cell.taskId = "ep-t2" // staged replacement (baseline stays ep-t1)
            draft["0-0"] = cell
        }

        let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let cells = buildSquaresEditCells(draft: draft, gridSize: 3, centerType: .free)

        return BoardEditPanel(
            board: board,
            cells: cells,
            taskMap: taskMap,
            editCount: editCount,
            canShuffle: true,
            isSaving: isSaving,
            onSave: {},
            onCancelConfirmed: {}
        )
    }
}
