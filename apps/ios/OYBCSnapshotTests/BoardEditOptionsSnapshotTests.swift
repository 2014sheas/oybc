import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Board Edit consolidation (D1–D9 —
/// docs/BOARD_EDIT_REDESIGN.md §Slice 5): the Edit screen's BOARD section
/// (`BoardOptionsSectionView`) both standalone and composed inside
/// `BoardEditPanel`, plus the squares-hidden variant (D4) for ended /
/// closed / archived boards.
///
/// `now` is passed explicitly to every `BoardMenuItems` call rather than
/// read from the wall clock, so the ended/closed determinations (and the
/// board-item lists they drive) are deterministic regardless of when the
/// suite runs.
final class BoardEditOptionsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    /// 2026-03-31T00:00:00.000Z — before the Ended scenario's board
    /// `endDate` (2026-04-30), so `isBoardEnded` reads false at this instant.
    private let liveNow: Double = 1_774_915_200_000
    /// 2026-05-25T00:00:00.000Z — after the Ended scenario's board
    /// `endDate`, so `isBoardEnded` reads true at this instant.
    private let pastEndDateNow: Double = 1_779_667_200_000

    // MARK: - Active, dirty, with the BOARD section in frame

    func testActiveDirtyWithBoardSectionLight() {
        assertSnapshot(
            of: activePanel(dirty: true),
            as: .image(layout: .fixed(width: 393, height: 1300)),
            record: recordMode
        )
    }

    func testActiveDirtyWithBoardSectionDark() {
        assertSnapshot(
            of: activePanel(dirty: true),
            as: .image(
                layout: .fixed(width: 393, height: 1300),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Ended, ad-hoc: SQUARES hidden, Close leads the BOARD section

    func testEndedAdhocSquaresHidden() {
        let board = SnapshotFixtures.makeBoard(
            id: "eo-ended", name: "Spring Goals", boardSize: 3,
            timeframe: .custom,
            startDate: "2026-04-01T00:00:00.000Z", endDate: "2026-04-30T23:59:59.000Z"
        )
        assertSnapshot(
            of: lockedPanel(board: board, now: pastEndDateNow),
            as: .image(layout: .fixed(width: 393, height: 760)),
            record: recordMode
        )
    }

    // MARK: - Closed core: SQUARES hidden, Reopen · Core defaults… · Delete

    func testClosedCoreLight() {
        assertSnapshot(
            of: closedCorePanel(),
            as: .image(layout: .fixed(width: 393, height: 560)),
            record: recordMode
        )
    }

    func testClosedCoreDark() {
        assertSnapshot(
            of: closedCorePanel(),
            as: .image(
                layout: .fixed(width: 393, height: 560),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Archived: SQUARES hidden, Delete only

    func testArchivedDeleteOnly() {
        let board = SnapshotFixtures.makeBoard(
            id: "eo-archived", name: "Spring Goals", boardSize: 3,
            status: .archived
        )
        assertSnapshot(
            of: lockedPanel(board: board, now: liveNow),
            as: .image(layout: .fixed(width: 393, height: 420)),
            record: recordMode
        )
    }

    // MARK: - The BOARD section as a standalone leaf

    func testOptionsSectionLeafLight() {
        assertSnapshot(
            of: optionsLeaf(),
            as: .image(layout: .fixed(width: 393, height: 320)),
            record: recordMode
        )
    }

    func testOptionsSectionLeafDark() {
        assertSnapshot(
            of: optionsLeaf(),
            as: .image(
                layout: .fixed(width: 393, height: 320),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - View builders

    private func optionsLeaf() -> some View {
        BoardOptionsSectionView(
            items: [.details, .repeatBoard, .archive, .delete],
            onSelect: { _ in }
        )
        .padding(Riso.gutter)
        .background(Color.risoPaper)
    }

    /// A fully-populated, editable 3×3 board — mirrors
    /// `BoardEditPanelSnapshotTests.makePanel`, with the BOARD section wired.
    private func activePanel(dirty: Bool) -> some View {
        let board = SnapshotFixtures.makeBoard(id: "eo-active", name: "Spring Goals", boardSize: 3)

        let tasks: [Task] = (1...9).compactMap { i -> Task? in
            i == 5 ? nil : SnapshotFixtures.makeTask(id: "eo-t\(i)", title: "Task \(i)", type: .normal)
        }
        let slots = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 2), (2, 0), (2, 1), (2, 2)]
        let ids = [1, 2, 3, 4, 6, 7, 8, 9]
        var boardTasks: [BoardTask] = []
        for (idx, taskNum) in ids.enumerated() {
            let (row, col) = slots[idx]
            boardTasks.append(SnapshotFixtures.makeBoardTask(
                id: "eo-bt\(taskNum)", boardId: "eo-active", taskId: "eo-t\(taskNum)", row: row, col: col
            ))
        }

        var draft = SnapshotFixtures.makeSquaresDraft(from: boardTasks)
        if dirty, var cell = draft["0-0"] {
            cell.taskId = "eo-t2"
            draft["0-0"] = cell
        }

        let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let cells = buildSquaresEditCells(draft: draft, gridSize: 3, centerType: .free)

        return BoardEditPanel(
            board: board,
            cells: cells,
            taskMap: taskMap,
            editCount: dirty ? 1 : 0,
            canShuffle: true,
            isSaving: false,
            onSave: {},
            onCancelConfirmed: {},
            boardItems: [.details, .repeatBoard, .archive, .delete],
            onBoardItem: { _ in }
        )
    }

    /// The squares-hidden variant (D4) — no grid, the locked-reason line,
    /// then the BOARD section computed live from `BoardMenuItems`.
    private func lockedPanel(board: Board, now: Double) -> some View {
        BoardEditPanel(
            board: board,
            cells: [],
            taskMap: [:],
            editCount: 0,
            canShuffle: false,
            isSaving: false,
            onSave: {},
            onCancelConfirmed: {},
            squaresEditable: false,
            squaresLockedReason: BoardMenuItems.squaresLockedReason(board: board, now: now),
            boardItems: BoardMenuItems.items(board: board, sourceTemplate: nil, now: now),
            onBoardItem: { _ in }
        )
    }

    private func closedCorePanel() -> some View {
        let board = SnapshotFixtures.makeBoard(
            id: "eo-closed-core", name: "Today", boardSize: 3,
            timeframe: .daily,
            startDate: "2026-04-01T00:00:00.000Z", endDate: "2026-04-01T23:59:59.000Z",
            isCore: true,
            sealedAt: "2026-04-02T06:00:00.000Z"
        )
        return lockedPanel(board: board, now: liveNow)
    }
}
