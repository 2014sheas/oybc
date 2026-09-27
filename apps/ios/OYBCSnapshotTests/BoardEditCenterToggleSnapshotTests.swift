import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the center Free ⇄ task-square toggle states
/// (D16) in the unified `BoardEditPanel` grid (Board Edit redesign slice 3).
///
/// Strategy: render `BoardEditPanel` directly with hardcoded props so no
/// `AppDatabase.shared` or `@EnvironmentObject` wiring is needed.
///
/// Scenarios covered:
///   - FREE center: gold star cell, never lifts, tappable for the menu
///   - NONE center with task: renders like a normal occupied cell (no gold)
///   - NONE center empty: a plain dashed empty square (tappable to add)
///
/// Determinism:
///   - Fixed dates pinned to 2026-04-01 / 2026-04-30 UTC noon.
///   - `record: .missing` — baselines are auto-recorded on first run.
final class BoardEditCenterToggleSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - FREE center

    func testFreeCenterInteractiveLight() {
        assertSnapshot(
            of: makePanel(centerType: .free, populateCenter: false),
            as: .image(layout: .fixed(width: 393, height: 1250)),
            record: recordMode
        )
    }

    func testFreeCenterInteractiveDark() {
        assertSnapshot(
            of: makePanel(centerType: .free, populateCenter: false),
            as: .image(
                layout: .fixed(width: 393, height: 1250),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - NONE center with task

    /// Expect: center cell is NOT gold; it renders as a normal occupied cell
    /// with a pencil chip when dirty — no special center styling remains.
    func testNoneCenterWithTaskLight() {
        assertSnapshot(
            of: makePanel(centerType: .none, populateCenter: true),
            as: .image(layout: .fixed(width: 393, height: 1250)),
            record: recordMode
        )
    }

    func testNoneCenterWithTaskDark() {
        assertSnapshot(
            of: makePanel(centerType: .none, populateCenter: true),
            as: .image(
                layout: .fixed(width: 393, height: 1250),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - NONE center empty (after converting FREE → NONE)

    /// Expect: center slot is a plain dashed empty square — tappable to add,
    /// no gold, no chip.
    func testNoneCenterEmptyLight() {
        assertSnapshot(
            of: makePanel(centerType: .none, populateCenter: false),
            as: .image(layout: .fixed(width: 393, height: 1250)),
            record: recordMode
        )
    }

    // MARK: - View builder

    /// - Parameters:
    ///   - centerType: The EFFECTIVE center type — `.free` or `.none`.
    ///   - populateCenter: When true, a task is placed at (1,1) (center of
    ///     the 3×3 grid). When false the center slot is empty (only
    ///     meaningful for `.none` — `.free` never has a draft entry there).
    private func makePanel(
        centerType: CenterSquareType,
        populateCenter: Bool
    ) -> some View {
        let board = SnapshotFixtures.makeBoard(id: "ct-board-1", name: "Center Toggle Test", boardSize: 3)

        var tasks: [Task] = [
            SnapshotFixtures.makeTask(id: "ct-t1", title: "Morning workout", type: .normal),
            SnapshotFixtures.makeTask(id: "ct-t2", title: "Cook a meal",     type: .normal, isCompleted: true),
            SnapshotFixtures.makeTask(id: "ct-t3", title: "Call a friend",   type: .normal),
            SnapshotFixtures.makeTask(id: "ct-t4", title: "Read 50 pages",   type: .counting,
                                      action: "Read", unit: "pages", maxCount: 50),
            SnapshotFixtures.makeTask(id: "ct-t6", title: "Write in journal", type: .normal),
            SnapshotFixtures.makeTask(id: "ct-t7", title: "Take a walk",     type: .normal),
            SnapshotFixtures.makeTask(id: "ct-t8", title: "Stretch",         type: .normal),
            SnapshotFixtures.makeTask(id: "ct-t9", title: "Drink 8 glasses", type: .counting,
                                      action: "Drink", unit: "glasses", maxCount: 8),
        ]

        var boardTasks: [BoardTask] = [
            SnapshotFixtures.makeBoardTask(id: "ct-bt1", boardId: "ct-board-1", taskId: "ct-t1", row: 0, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ct-bt2", boardId: "ct-board-1", taskId: "ct-t2", row: 0, col: 1),
            SnapshotFixtures.makeBoardTask(id: "ct-bt3", boardId: "ct-board-1", taskId: "ct-t3", row: 0, col: 2),
            SnapshotFixtures.makeBoardTask(id: "ct-bt4", boardId: "ct-board-1", taskId: "ct-t4", row: 1, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ct-bt6", boardId: "ct-board-1", taskId: "ct-t6", row: 1, col: 2),
            SnapshotFixtures.makeBoardTask(id: "ct-bt7", boardId: "ct-board-1", taskId: "ct-t7", row: 2, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ct-bt8", boardId: "ct-board-1", taskId: "ct-t8", row: 2, col: 1),
            SnapshotFixtures.makeBoardTask(id: "ct-bt9", boardId: "ct-board-1", taskId: "ct-t9", row: 2, col: 2),
        ]

        if populateCenter {
            tasks.append(SnapshotFixtures.makeTask(id: "ct-t5", title: "Meditate 10 min", type: .normal))
            boardTasks.append(SnapshotFixtures.makeBoardTask(
                id: "ct-bt5", boardId: "ct-board-1", taskId: "ct-t5", row: 1, col: 1, isCenter: false
            ))
        }

        let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let draft = SnapshotFixtures.makeSquaresDraft(from: boardTasks)
        let cells = buildSquaresEditCells(draft: draft, gridSize: 3, centerType: centerType)

        return BoardEditPanel(
            board: board,
            cells: cells,
            taskMap: taskMap,
            editCount: 0,
            canShuffle: true,
            isSaving: false,
            onSave: {},
            onCancelConfirmed: {}
        )
    }
}
