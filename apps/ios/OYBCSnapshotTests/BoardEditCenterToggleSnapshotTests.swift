import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for Phase-2b "center Free⇄Task toggle" states
/// in the `BoardEditPanel` static grid.
///
/// Strategy: render `BoardEditPanel` directly with constant bindings so no
/// `AppDatabase.shared` or `@EnvironmentObject` wiring is needed. Each test
/// exercises one distinct center-toggle scenario.
///
/// Scenarios covered:
///   - FREE center: shows gold star cell + pencil affordance (toggle available)
///   - NONE center with task: task cell at center is rendered like a normal cell
///     (blue border + pencil badge — NOT gold FREE)
///   - NONE center empty: empty placeholder at center (no task, no affordance)
///
/// Determinism:
///   - Fixed dates pinned to 2026-04-01 / 2026-04-30 UTC noon.
///   - `weekStartDay: "monday"` throughout.
///   - `record: .missing` — baselines are auto-recorded on first run.
final class BoardEditCenterToggleSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private static let fixedStart = Date(timeIntervalSince1970: 1_743_508_800)  // 2026-04-01 noon UTC
    private static let fixedEnd   = Date(timeIntervalSince1970: 1_746_100_800)  // 2026-04-30 noon UTC

    // MARK: - FREE center (edit-tasks sub-mode, onCenterTap active)

    /// Renders a 3×3 board whose center is `.free`.
    /// Expect: center cell is gold with a star + pencil badge signalling the toggle.
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

    // MARK: - NONE center with task (predicate fix: renders as normal tappable cell)

    /// Renders a 3×3 board whose center is `.none` with a task placed there.
    /// Expect: center cell is NOT gold; it renders as a normal occupied cell
    /// with blue border + pencil badge (same as all other occupied cells).
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

    /// Renders a 3×3 board whose center is `.none` with no task at the center
    /// position (the state immediately after converting from FREE → NONE).
    /// Expect: center slot is an empty placeholder — not gold, not interactive.
    func testNoneCenterEmptyLight() {
        assertSnapshot(
            of: makePanel(centerType: .none, populateCenter: false),
            as: .image(layout: .fixed(width: 393, height: 1250)),
            record: recordMode
        )
    }

    // MARK: - View builder

    /// Builds a `BoardEditPanel` for center-toggle snapshot variants.
    ///
    /// - Parameters:
    ///   - centerType: Draft center type — `.free` or `.none`.
    ///   - populateCenter: When true, a task is placed at row=1, col=1 (center
    ///     of the 3×3 grid) so the center slot has a task. When false the center
    ///     slot is empty.
    private func makePanel(
        centerType: CenterSquareType,
        populateCenter: Bool
    ) -> some View {
        // Board fixture — 3×3 monthly active board.
        let board = SnapshotFixtures.makeBoard(
            id: "ct-board-1",
            name: "Center Toggle Test",
            boardSize: 3
        )

        // Eight surrounding tasks (no center task by default).
        let surroundTasks: [Task] = [
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

        var tasks = surroundTasks
        var centerBoardTask: BoardTask? = nil
        if populateCenter {
            let centerTask = SnapshotFixtures.makeTask(
                id: "ct-t5", title: "Meditate 10 min", type: .normal
            )
            tasks.append(centerTask)
            centerBoardTask = SnapshotFixtures.makeBoardTask(
                id: "ct-bt5", boardId: "ct-board-1", taskId: "ct-t5",
                row: 1, col: 1,
                // isCenter is the DB flag. For .none center, the task at the
                // center position would NOT have isCenter=true in the DB
                // (no CHOSEN pin); we set it false to mirror real data.
                isCenter: false
            )
        }

        let boardTasks: [BoardTask] = [
            SnapshotFixtures.makeBoardTask(id: "ct-bt1", boardId: "ct-board-1", taskId: "ct-t1", row: 0, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ct-bt2", boardId: "ct-board-1", taskId: "ct-t2", row: 0, col: 1),
            SnapshotFixtures.makeBoardTask(id: "ct-bt3", boardId: "ct-board-1", taskId: "ct-t3", row: 0, col: 2),
            SnapshotFixtures.makeBoardTask(id: "ct-bt4", boardId: "ct-board-1", taskId: "ct-t4", row: 1, col: 0),
            // center slot: conditionally populated above
            SnapshotFixtures.makeBoardTask(id: "ct-bt6", boardId: "ct-board-1", taskId: "ct-t6", row: 1, col: 2),
            SnapshotFixtures.makeBoardTask(id: "ct-bt7", boardId: "ct-board-1", taskId: "ct-t7", row: 2, col: 0),
            SnapshotFixtures.makeBoardTask(id: "ct-bt8", boardId: "ct-board-1", taskId: "ct-t8", row: 2, col: 1),
            SnapshotFixtures.makeBoardTask(id: "ct-bt9", boardId: "ct-board-1", taskId: "ct-t9", row: 2, col: 2),
        ] + (centerBoardTask.map { [$0] } ?? [])

        let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        return BoardEditPanel(
            board: board,
            boardTasks: boardTasks,
            taskMap: taskMap,
            weekStartDay: "monday",
            originalCustomStartDate: Self.fixedStart,
            originalCustomEndDate: Self.fixedEnd,
            name: .constant("Center Toggle Test"),
            timeframe: .constant(.monthly),
            customStartDate: .constant(Self.fixedStart),
            customEndDate: .constant(Self.fixedEnd),
            centerType: .constant(centerType),
            hasCandidateTasks: false,
            subMode: .constant(.editTasks),
            squareEditCount: 0,
            // Supply non-nil callbacks so the grid renders interactive affordances.
            onCellTap: { _, _ in },
            onCenterTap: { },
            isSaving: false,
            onSave: {},
            onCancelConfirmed: {},
            onArchiveConfirmed: {}
        )
    }
}
