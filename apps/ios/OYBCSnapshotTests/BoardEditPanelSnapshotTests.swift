import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Phase 1 in-place board edit chrome (`BoardEditPanel`).
///
/// Strategy: render the leaf view directly with constant bindings so no
/// `AppDatabase.shared` access or `@EnvironmentObject` wiring is needed.
/// Four scenarios are covered:
///   - Clean/light  — all bindings match the board's stored values (Save disabled)
///   - Clean/dark   — same in dark mode
///   - Dirty/light  — `name` differs from board.name (edit-count and Save pill active)
///   - Saving/light — `isSaving: true` (pill shows "Saving…", Save still disabled)
///
/// Determinism rules (mirrors `RisoEditBoardSnapshotTests`):
///   - Board fixture built via `SnapshotFixtures.makeBoard` (no live DB).
///   - Task / BoardTask fixtures for a populated 3×3 grid.
///   - Fixed dates pinned to 2026-04-01 / 2026-04-30 UTC noon.
///   - `weekStartDay: "monday"` throughout.
///   - Non-custom timeframe date notes depend on wall-clock date (acceptable — see
///     `reference_snapshot_date_dependent.md`; structural chrome is what we guard).
final class BoardEditPanelSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // Fixed pinned dates — 2026-04-01T12:00:00Z and 2026-04-30T12:00:00Z.
    private static let fixedStart = Date(timeIntervalSince1970: 1_743_508_800)  // 2026-04-01 noon UTC
    private static let fixedEnd   = Date(timeIntervalSince1970: 1_746_100_800)  // 2026-04-30 noon UTC

    // MARK: - Tests

    func testPanelMonthlyCleanLight() {
        assertSnapshot(
            of: makePanel(),
            as: .image(layout: .fixed(width: 393, height: 1250)),
            record: recordMode
        )
    }

    func testPanelMonthlyCleanDark() {
        assertSnapshot(
            of: makePanel(),
            as: .image(
                layout: .fixed(width: 393, height: 1250),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    /// Dirty state: `name` binding differs from `board.name`.
    /// Expect: edit counter shows "1 edit", Save pill is gold and enabled.
    func testPanelDirtyLight() {
        assertSnapshot(
            of: makePanel(name: "Spring Goals — Updated"),
            as: .image(layout: .fixed(width: 393, height: 1250)),
            record: recordMode
        )
    }

    /// Saving state: `isSaving: true` forces pill text to "Saving…".
    func testPanelSavingLight() {
        assertSnapshot(
            of: makePanel(name: "Spring Goals — Updated", isSaving: true),
            as: .image(layout: .fixed(width: 393, height: 1250)),
            record: recordMode
        )
    }

    // MARK: - View builder

    /// Builds a `BoardEditPanel` with constant bindings. All task / boardTask data is
    /// hardcoded so the same pixel output is produced regardless of DB state.
    ///
    /// - Parameters:
    ///   - name: Value for the draft `name` binding (defaults to board.name → clean state).
    ///   - isSaving: Whether to render the saving indicator state.
    private func makePanel(
        name: String = "Spring Goals",
        isSaving: Bool = false
    ) -> some View {
        // Board fixture — 3×3 monthly active board.
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
            weekStartDay: "monday",
            originalCustomStartDate: Self.fixedStart,
            originalCustomEndDate: Self.fixedEnd,
            name: .constant(name),
            timeframe: .constant(.monthly),
            customStartDate: .constant(Self.fixedStart),
            customEndDate: .constant(Self.fixedEnd),
            centerType: .constant(.free),
            centerCustomName: .constant(""),
            hasCandidateTasks: false,
            subMode: .constant(.editTasks),
            isSaving: isSaving,
            onSave: {},
            onCancelConfirmed: {},
            onArchiveConfirmed: {}
        )
    }
}
