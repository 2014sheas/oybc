import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Board Edit redesign slice 3 squares editor
/// (`SquaresEditGrid` + `SquarePickerSheetView`) — the single-mode grid that
/// replaced the retired Edit-tasks ⇄ Rearrange sub-modes (D7).
///
/// Strategy: render the leaf views directly with hardcoded props — no
/// `AppDatabase.shared` or `@EnvironmentObject` wiring needed.
final class SquaresEditSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private let sideLength: CGFloat = 393 - 2 * Riso.gutter

    // MARK: - Fixtures

    private func makeTasks() -> [Task] {
        [
            SnapshotFixtures.makeTask(id: "se-t1", title: "Morning workout", type: .normal),
            SnapshotFixtures.makeTask(id: "se-t2", title: "Cook a meal",     type: .normal, isCompleted: true),
            SnapshotFixtures.makeTask(id: "se-t3", title: "Call a friend",   type: .normal),
            SnapshotFixtures.makeTask(id: "se-t4", title: "Read 50 pages",   type: .counting,
                                      action: "Read", unit: "pages", maxCount: 50),
            SnapshotFixtures.makeTask(id: "se-t6", title: "Write in journal", type: .normal),
            SnapshotFixtures.makeTask(id: "se-t7", title: "Take a walk",     type: .normal),
            SnapshotFixtures.makeTask(id: "se-t8", title: "Stretch",         type: .normal),
            SnapshotFixtures.makeTask(id: "se-t9", title: "Drink 8 glasses", type: .counting,
                                      action: "Drink", unit: "glasses", maxCount: 8),
        ]
    }

    private func makeBoardTasks(boardId: String, includeCenter: Bool, centerLocked: Bool = false) -> [BoardTask] {
        var rows: [BoardTask] = [
            SnapshotFixtures.makeBoardTask(id: "se-bt1", boardId: boardId, taskId: "se-t1", row: 0, col: 0),
            SnapshotFixtures.makeBoardTask(id: "se-bt2", boardId: boardId, taskId: "se-t2", row: 0, col: 1),
            SnapshotFixtures.makeBoardTask(id: "se-bt3", boardId: boardId, taskId: "se-t3", row: 0, col: 2),
            SnapshotFixtures.makeBoardTask(id: "se-bt4", boardId: boardId, taskId: "se-t4", row: 1, col: 0),
            SnapshotFixtures.makeBoardTask(id: "se-bt6", boardId: boardId, taskId: "se-t6", row: 1, col: 2),
            SnapshotFixtures.makeBoardTask(id: "se-bt7", boardId: boardId, taskId: "se-t7", row: 2, col: 0),
            SnapshotFixtures.makeBoardTask(id: "se-bt8", boardId: boardId, taskId: "se-t8", row: 2, col: 1),
            SnapshotFixtures.makeBoardTask(id: "se-bt9", boardId: boardId, taskId: "se-t9", row: 2, col: 2),
        ]
        if includeCenter {
            rows.append(SnapshotFixtures.makeBoardTask(
                id: "se-bt5", boardId: boardId, taskId: "se-t9", row: 1, col: 1, isCenter: false
            ))
        }
        return rows
    }

    private func makeGrid(
        draft: [String: SquaresDraftCell],
        centerType: CenterSquareType,
        taskMap: [String: Task]
    ) -> some View {
        let cells = buildSquaresEditCells(draft: draft, gridSize: 3, centerType: centerType)
        return SquaresEditGrid(
            cells: cells,
            gridSize: 3,
            taskMap: taskMap,
            sideLength: sideLength,
            onTap: { _ in },
            onReorder: { _ in },
            onKeyboardMove: { _, _ in .ignored }
        )
        .padding(Riso.gutter)
        .background(Color.risoPaper)
    }

    // MARK: - i2: clean grid (FREE center, 8 tasks, one already dirty-free)

    func testEditCleanLight() {
        let taskMap = Dictionary(uniqueKeysWithValues: makeTasks().map { ($0.id, $0) })
        let draft = SnapshotFixtures.makeSquaresDraft(from: makeBoardTasks(boardId: "se-b1", includeCenter: false))
        assertSnapshot(
            of: makeGrid(draft: draft, centerType: .free, taskMap: taskMap),
            as: .image(layout: .fixed(width: 393, height: 460)),
            record: recordMode
        )
    }

    func testEditCleanDark() {
        let taskMap = Dictionary(uniqueKeysWithValues: makeTasks().map { ($0.id, $0) })
        let draft = SnapshotFixtures.makeSquaresDraft(from: makeBoardTasks(boardId: "se-b1", includeCenter: false))
        assertSnapshot(
            of: makeGrid(draft: draft, centerType: .free, taskMap: taskMap),
            as: .image(
                layout: .fixed(width: 393, height: 460),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - i3: two staged edits — a removed (empty) square + a locked square

    func testEditTwoEditsEmptyAndLockedLight() {
        let taskMap = Dictionary(uniqueKeysWithValues: makeTasks().map { ($0.id, $0) })
        var boardTasks = makeBoardTasks(boardId: "se-b1", includeCenter: false)
        boardTasks.removeAll { $0.id == "se-bt3" } // (0,2) is now an empty, dashed square
        var draft = SnapshotFixtures.makeSquaresDraft(from: boardTasks)
        if var locked = draft["1-0"] {
            locked.isLocked = true
            draft["1-0"] = locked
        }
        assertSnapshot(
            of: makeGrid(draft: draft, centerType: .free, taskMap: taskMap),
            as: .image(layout: .fixed(width: 393, height: 460)),
            record: recordMode
        )
    }

    func testEditTwoEditsEmptyAndLockedDark() {
        let taskMap = Dictionary(uniqueKeysWithValues: makeTasks().map { ($0.id, $0) })
        var boardTasks = makeBoardTasks(boardId: "se-b1", includeCenter: false)
        boardTasks.removeAll { $0.id == "se-bt3" }
        var draft = SnapshotFixtures.makeSquaresDraft(from: boardTasks)
        if var locked = draft["1-0"] {
            locked.isLocked = true
            draft["1-0"] = locked
        }
        assertSnapshot(
            of: makeGrid(draft: draft, centerType: .free, taskMap: taskMap),
            as: .image(
                layout: .fixed(width: 393, height: 460),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Legacy-CHOSEN center: a normal cell with the lock chip, no gold

    func testEditLegacyChosenCenterLocked() {
        let taskMap = Dictionary(uniqueKeysWithValues: makeTasks().map { ($0.id, $0) })
        let boardTasks = makeBoardTasks(boardId: "se-b1", includeCenter: true)
        var draft = SnapshotFixtures.makeSquaresDraft(from: boardTasks)
        // The implicit legacy-CHOSEN lock (D1) is the BASELINE, not a staged
        // change — both `isLocked` and `originalIsLocked` are true, so the
        // cell shows the lock chip WITHOUT the dirty pencil.
        if let seeded = draft["1-1"] {
            draft["1-1"] = SquaresDraftCell(
                id: seeded.id, isNew: false, taskId: seeded.taskId, pending: nil,
                isLocked: true, originalRow: seeded.originalRow, originalCol: seeded.originalCol,
                originalTaskId: seeded.originalTaskId, originalIsLocked: true
            )
        }
        assertSnapshot(
            of: makeGrid(draft: draft, centerType: .none, taskMap: taskMap),
            as: .image(layout: .fixed(width: 393, height: 460)),
            record: recordMode
        )
    }

    // MARK: - FREE center

    func testEditFreeCenter() {
        let taskMap = Dictionary(uniqueKeysWithValues: makeTasks().map { ($0.id, $0) })
        let draft = SnapshotFixtures.makeSquaresDraft(from: makeBoardTasks(boardId: "se-b1", includeCenter: false))
        assertSnapshot(
            of: makeGrid(draft: draft, centerType: .free, taskMap: taskMap),
            as: .image(layout: .fixed(width: 393, height: 460)),
            record: recordMode
        )
    }

    // MARK: - i5: the Square picker sheet

    private func makeCandidates() -> [Task] {
        [
            SnapshotFixtures.makeTask(id: "se-c1", title: "Meditate 10 min", type: .normal),
            SnapshotFixtures.makeTask(id: "se-c2", title: "Read 30 min",     type: .normal),
            SnapshotFixtures.makeTask(id: "se-c3", title: "Journal",         type: .normal),
        ]
    }

    func testPickerReplaceLight() {
        assertSnapshot(
            of: SquarePickerSheetView(
                mode: .replace(currentTaskId: "se-t1"),
                userId: "u1",
                candidateTasks: makeCandidates(),
                onDismiss: {},
                onConfirm: { _, _ in }
            ),
            as: .image(layout: .fixed(width: 393, height: 500)),
            record: recordMode
        )
    }

    func testPickerReplaceDark() {
        assertSnapshot(
            of: SquarePickerSheetView(
                mode: .replace(currentTaskId: "se-t1"),
                userId: "u1",
                candidateTasks: makeCandidates(),
                onDismiss: {},
                onConfirm: { _, _ in }
            ),
            as: .image(
                layout: .fixed(width: 393, height: 500),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    func testPickerAdd() {
        assertSnapshot(
            of: SquarePickerSheetView(
                mode: .add,
                userId: "u1",
                candidateTasks: makeCandidates(),
                onDismiss: {},
                onConfirm: { _, _ in }
            ),
            as: .image(layout: .fixed(width: 393, height: 500)),
            record: recordMode
        )
    }
}
