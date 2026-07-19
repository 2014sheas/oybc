import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Riso reskin of the wizard "From a board…"
/// library sub-flows:
///
///   - `FromBoardPickerView`  — source-board list (boards to choose from)
///   - `FromBoardGridView`    — chosen board's task grid
///   - `CopyTaskSheet`        — "⎘ Add a copy of this task…" modal
///
/// These views are snapshot-testable as prop-taking leaf views — they do
/// not self-load from `AppDatabase.shared`. All fixtures are seeded via
/// `SnapshotFixtures` builders.
///
/// Exception (bugfix/board-preview-real-cells): `FromBoardPickerView`'s row
/// thumbnail now renders through `RisoBoardPreviewGrid`, which self-loads the
/// TRUE preview grid per board id. The picker fixtures below never persist
/// their boards to `AppDatabase.shared` (only `vm.eligibleBoards`/
/// `vm.completionByBoardId` are stubbed in-memory), so the thumbnail
/// deterministically renders empty — a real fixture would need a seeded
/// `AppDatabase.makeTestInstance()`, out of scope for this leaf-view suite.
///
/// Light + dark for every variant. `recordMode: .missing` auto-records
/// baselines on first run and passes green on subsequent runs.
final class RisoWizardLibrarySnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - FromBoardPickerView

    /// Empty state — no eligible boards.
    func testPickerEmpty_light() {
        let vm = emptySourceBoardsVM()
        let view = pickerWrapper(vm: vm)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200)),
            record: recordMode
        )
    }

    func testPickerEmpty_dark() {
        let vm = emptySourceBoardsVM()
        let view = pickerWrapper(vm: vm)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 200),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    /// Populated state — three board rows.
    func testPickerBoards_light() {
        let vm = populatedSourceBoardsVM()
        let view = pickerWrapper(vm: vm)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 380)),
            record: recordMode
        )
    }

    func testPickerBoards_dark() {
        let vm = populatedSourceBoardsVM()
        let view = pickerWrapper(vm: vm)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 380),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - FromBoardGridView

    /// Empty placements — "Nothing to add from this board."
    func testGridEmpty_light() {
        let vm = emptySourceBoardsVM()
        let board = SnapshotFixtures.makeBoard(id: "source-b1", name: "Weekly Wellness")
        let view = gridWrapper(vm: vm, board: board, selected: [], copied: [])
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 120)),
            record: recordMode
        )
    }

    func testGridEmpty_dark() {
        let vm = emptySourceBoardsVM()
        let board = SnapshotFixtures.makeBoard(id: "source-b1", name: "Weekly Wellness")
        let view = gridWrapper(vm: vm, board: board, selected: [], copied: [])
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 120),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    /// Populated 3×3 grid — mix of resting / linked (gold) / copied (green) cells.
    func testGrid3x3_light() {
        let board = SnapshotFixtures.makeBoard(
            id: "source-b2",
            name: "April Sprint",
            boardSize: 3,
            timeframe: .monthly,
            status: .active,
            startDate: "2026-04-01T00:00:00.000Z",
            endDate: "2026-04-30T23:59:59.000Z"
        )
        let vm = gridSourceVM(board: board)
        // t-grid-1 linked, t-grid-2 copied, rest resting
        let view = gridWrapper(
            vm: vm,
            board: board,
            selected: ["t-grid-1"],
            copied: ["t-grid-2"]
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 380)),
            record: recordMode
        )
    }

    func testGrid3x3_dark() {
        let board = SnapshotFixtures.makeBoard(
            id: "source-b2",
            name: "April Sprint",
            boardSize: 3,
            timeframe: .monthly,
            status: .active,
            startDate: "2026-04-01T00:00:00.000Z",
            endDate: "2026-04-30T23:59:59.000Z"
        )
        let vm = gridSourceVM(board: board)
        let view = gridWrapper(
            vm: vm,
            board: board,
            selected: ["t-grid-1"],
            copied: ["t-grid-2"]
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 380),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - CopyTaskSheet

    /// Normal task copy — title field only.
    func testCopyNormal_light() {
        let source = SnapshotFixtures.makeTask(
            id: "src-normal",
            title: "Morning workout",
            type: .normal
        )
        let view = copySheetWrapper(source: source)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 520)),
            record: recordMode
        )
    }

    func testCopyNormal_dark() {
        let source = SnapshotFixtures.makeTask(
            id: "src-normal",
            title: "Morning workout",
            type: .normal
        )
        let view = copySheetWrapper(source: source)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 520),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    /// Counting task copy — shows action / goal / unit fields.
    func testCopyCounting_light() {
        let source = SnapshotFixtures.makeTask(
            id: "src-counting",
            title: "Read 100 pages",
            type: .counting,
            action: "Read",
            unit: "pages",
            maxCount: 100
        )
        let view = copySheetWrapper(source: source)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 620)),
            record: recordMode
        )
    }

    func testCopyCounting_dark() {
        let source = SnapshotFixtures.makeTask(
            id: "src-counting",
            title: "Read 100 pages",
            type: .counting,
            action: "Read",
            unit: "pages",
            maxCount: 100
        )
        let view = copySheetWrapper(source: source)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 620),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    /// Compound task copy — shows shared-children note.
    func testCopyCompound_light() {
        let source = SnapshotFixtures.makeTask(
            id: "src-compound",
            title: "Daily wellness",
            type: .compound,
            operatorType: .and
        )
        let view = copySheetWrapper(source: source)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 560)),
            record: recordMode
        )
    }

    func testCopyCompound_dark() {
        let source = SnapshotFixtures.makeTask(
            id: "src-compound",
            title: "Daily wellness",
            type: .compound,
            operatorType: .and
        )
        let view = copySheetWrapper(source: source)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 560),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Helpers

    /// Wraps `FromBoardPickerView` in a paper-background scroll for snapshot isolation.
    private func pickerWrapper(vm: SourceBoardsViewModel) -> some View {
        ZStack {
            RisoPaperBackground()
            ScrollView {
                FromBoardPickerView(
                    vm: vm,
                    userId: SnapshotFixtures.userId,
                    onPickBoard: { _ in }
                )
                .padding(16)
            }
        }
    }

    /// Wraps `FromBoardGridView` in a paper-background scroll for snapshot isolation.
    private func gridWrapper(
        vm: SourceBoardsViewModel,
        board: Board,
        selected: Set<String>,
        copied: Set<String>
    ) -> some View {
        ZStack {
            RisoPaperBackground()
            ScrollView {
                FromBoardGridView(
                    vm: vm,
                    sourceBoard: board,
                    userId: SnapshotFixtures.userId,
                    selectedTaskIds: selected,
                    copiedTaskIds: copied,
                    onToggleSelection: { _ in },
                    onCopyTask: { _ in },
                    onAddAllSubtasks: { _, _ in },
                    onOpenInLibrary: { _ in },
                    onChangeSource: {},
                    onTaskCreated: { _ in }
                )
                .padding(16)
            }
        }
    }

    /// Wraps `CopyTaskSheet` body content for snapshot isolation.
    /// `CopyTaskSheet` is a NavigationStack sheet; we snapshot it directly
    /// at a fixed height that captures all visible fields.
    private func copySheetWrapper(source: OYBC.Task) -> some View {
        CopyTaskSheet(
            source: source,
            userId: SnapshotFixtures.userId,
            onCopied: { _ in },
            onCancel: {}
        )
    }

    // MARK: - VM builders

    /// `SourceBoardsViewModel` with no boards — produces the empty state.
    private func emptySourceBoardsVM() -> SourceBoardsViewModel {
        let vm = SourceBoardsViewModel()
        vm.eligibleBoards = []
        return vm
    }

    /// `SourceBoardsViewModel` pre-populated with three fixture boards.
    private func populatedSourceBoardsVM() -> SourceBoardsViewModel {
        let vm = SourceBoardsViewModel()
        let b1 = SnapshotFixtures.makeBoard(
            id: "sp-b1", name: "Weekly Wellness",
            boardSize: 5, timeframe: .weekly, status: .active,
            startDate: "2026-04-01T00:00:00.000Z",
            endDate:   "2026-04-07T23:59:59.000Z"
        )
        let b2 = SnapshotFixtures.makeBoard(
            id: "sp-b2", name: "April Reading Sprint",
            boardSize: 5, timeframe: .monthly, status: .active,
            startDate: "2026-04-01T00:00:00.000Z",
            endDate:   "2026-04-30T23:59:59.000Z"
        )
        let b3 = SnapshotFixtures.makeBoard(
            id: "sp-b3", name: "Fitness Goals",
            boardSize: 4, timeframe: .monthly, status: .completed,
            startDate: "2026-03-01T00:00:00.000Z",
            endDate:   "2026-03-31T23:59:59.000Z"
        )
        vm.eligibleBoards = [b1, b2, b3]
        vm.completionByBoardId = [
            "sp-b1": (12, 25),
            "sp-b2": (6,  25),
            "sp-b3": (16, 16),
        ]
        return vm
    }

    /// `SourceBoardsViewModel` with a 3×3 board's placements pre-loaded
    /// for `FromBoardGridView` snapshot tests.
    private func gridSourceVM(board: Board) -> SourceBoardsViewModel {
        let vm = SourceBoardsViewModel()
        vm.eligibleBoards = [board]

        // Build 9 tasks for the 3×3 grid
        let tasks: [(id: String, title: String)] = [
            ("t-grid-1", "Morning workout"),
            ("t-grid-2", "Read 30 min"),
            ("t-grid-3", "Meditate"),
            ("t-grid-4", "Cook at home"),
            ("t-grid-5", "FREE"),          // center (index 4 of 3×3)
            ("t-grid-6", "Journal"),
            ("t-grid-7", "Call a friend"),
            ("t-grid-8", "No screens after 9"),
            ("t-grid-9", "Early bedtime"),
        ]

        var placements: [SourceBoardPlacement] = []
        for (idx, t) in tasks.enumerated() {
            let row = idx / 3
            let col = idx % 3
            let isCenter = (row == 1 && col == 1) // center of 3×3
            // Skip center (free square) — the grid view handles it as a virtual cell
            if isCenter { continue }
            let task = SnapshotFixtures.makeTask(
                id: t.id,
                title: t.title,
                type: .normal
            )
            let boardTask = SnapshotFixtures.makeBoardTask(
                id: "bt-\(t.id)",
                boardId: board.id,
                taskId: t.id,
                row: row,
                col: col,
                isCenter: false
            )
            placements.append(SourceBoardPlacement(placement: boardTask, task: task))
        }
        vm.placements = placements
        return vm
    }
}
