import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// "Counts toward" PR 4 (docs/SHARED_COUNTER_SETTINGS.md §3) — the iOS
/// surfaces: C1 the Counter Detail section, C2 the "Counts toward" row in the
/// task editors (global + Board Edit) and its picker, C3 the board cell mark.
/// Pure props throughout (no `AppDatabase.shared`); candidates are injected.
final class CountsTowardSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Fixtures

    private func counter(_ id: String, _ name: String, count: CountValue = 12) -> Task {
        var t = SnapshotFixtures.makeTask(
            id: id, title: name, type: .counting, action: "Read", unit: "books", maxCount: 12, isCounter: true,
            counterName: name
        )
        t.currentCount = count
        return t
    }

    private func flagged(_ id: String, _ title: String, type: TaskType, amount: Int? = nil) -> Task {
        var t = SnapshotFixtures.makeTask(
            id: id, title: title, type: type, action: type == .counting ? "Run" : nil,
            unit: type == .counting ? "km" : nil, maxCount: type == .counting ? 5 : nil,
            operatorType: type == .compound ? .and : nil
        )
        t.countsTowardCounterId = "ct-books"
        t.countsTowardAmount = amount
        return t
    }

    private func row(
        _ id: String, _ status: CountsToward.ContributorRowStatus, board: String?, amount: Int = 1, credits: Int = 0
    ) -> CountsToward.ContributorRow {
        .init(taskId: id, status: status, boardId: board, amount: amount, creditCount: credits, latestOccurredAt: nil)
    }

    /// Six mixed rows like the handoff: done Simple on a yearly board, in-progress
    /// Counting on a weekly, in-progress Compound (+2) on a monthly, not-started
    /// Simple on a monthly, an unplaced Simple, an unplaced Compound; one "× 3".
    private func sixRows() -> CountsTowardSectionData {
        let tasks = [
            flagged("r1", "Read Dune", type: .normal),
            flagged("r2", "Run 5 km", type: .counting),
            flagged("r3", "Weekend reading block", type: .compound, amount: 2),
            flagged("r4", "Finish a novel", type: .normal),
            flagged("r5", "Visit the library", type: .normal),
            flagged("r6", "Reading club night", type: .compound),
        ]
        let boards = [
            SnapshotFixtures.makeBoard(id: "by", name: "2026 goals", timeframe: .yearly),
            SnapshotFixtures.makeBoard(id: "bw", name: "Week 42", timeframe: .weekly),
            SnapshotFixtures.makeBoard(id: "bm", name: "October", timeframe: .monthly),
        ]
        return CountsTowardSectionData(
            counterName: "Books",
            rows: [
                row("r1", .done, board: "by", credits: 3),
                row("r2", .inProgress, board: "bw"),
                row("r3", .inProgress, board: "bm", amount: 2),
                row("r4", .notStarted, board: "bm"),
                row("r5", .notStarted, board: nil),
                row("r6", .notStarted, board: nil),
            ],
            taskById: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) }),
            boardById: Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })
        )
    }

    private func section(_ data: CountsTowardSectionData) -> some View {
        CountsTowardSectionView(data: data)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.risoPaper)
    }

    private func dark(_ on: Bool) -> UITraitCollection { .init(userInterfaceStyle: on ? .dark : .light) }

    // MARK: - C1

    func testSectionSixRowsLight() {
        assertSnapshot(of: section(sixRows()), as: .image(layout: .fixed(width: 393, height: 470), traits: dark(false)), record: recordMode)
    }

    func testSectionSixRowsDark() {
        assertSnapshot(of: section(sixRows()), as: .image(layout: .fixed(width: 393, height: 470), traits: dark(true)), record: recordMode)
    }

    func testSectionEmptyLight() {
        let empty = CountsTowardSectionData(counterName: "Books", rows: [], taskById: [:], boardById: [:])
        assertSnapshot(of: section(empty), as: .image(layout: .fixed(width: 393, height: 150), traits: dark(false)), record: recordMode)
    }

    func testStatusPillsLight() {
        let pills = HStack(spacing: 8) {
            RisoStatusPill(status: .done)
            RisoStatusPill(status: .inProgress)
            RisoStatusPill(status: .notStarted)
        }
        .padding(16).background(Color.risoPaper)
        assertSnapshot(of: pills, as: .image(layout: .fixed(width: 393, height: 56), traits: dark(false)), record: recordMode)
    }

    // MARK: - C2

    private var pool: [Task] {
        [counter("ct-books", "Books"), counter("ct-novels", "Novels", count: 5), counter("ct-pages", "Pages", count: 1240)]
    }

    private func editSheet(_ task: Task) -> some View {
        EditTaskSheet(task: task, countsTowardTasks: pool + [task], onSubmit: { _ in }, onCancel: {})
    }

    func testEditTaskSheetFieldSetLight() {
        assertSnapshot(
            of: editSheet(flagged("ed-1", "Read Dune", type: .normal, amount: 1)),
            as: .image(layout: .fixed(width: 393, height: 600), traits: dark(false)), record: recordMode
        )
    }

    func testEditTaskSheetFieldNoneLight() {
        var task = flagged("ed-2", "Read Dune", type: .normal)
        task.countsTowardCounterId = nil
        assertSnapshot(
            of: editSheet(task),
            as: .image(layout: .fixed(width: 393, height: 600), traits: dark(false)), record: recordMode
        )
    }

    func testSquareEditSheetFieldSetAmount2Dark() {
        let task = flagged("sq-1", "Read Dune", type: .normal, amount: 2)
        assertSnapshot(
            of: SquareEditTaskSheet(task: task, countsTowardTasks: pool + [task], onDone: { _ in }, onCancel: {}),
            as: .image(layout: .fixed(width: 393, height: 560), traits: dark(true)), record: recordMode
        )
    }

    func testSquareEditSheetFieldNoneDark() {
        var task = flagged("sq-2", "Read Dune", type: .normal)
        task.countsTowardCounterId = nil
        assertSnapshot(
            of: SquareEditTaskSheet(task: task, countsTowardTasks: pool + [task], onDone: { _ in }, onCancel: {}),
            as: .image(layout: .fixed(width: 393, height: 560), traits: dark(true)), record: recordMode
        )
    }

    func testPickerOpenLight() {
        struct Host: View {
            let tasks: [Task]
            @State var sel = CountsTowardSelection(counterId: "ct-books", amount: 1)
            var body: some View {
                CountsTowardFieldView(
                    tasks: tasks, editedTaskId: nil, storedCounterId: nil, selection: $sel, initiallyOpen: true
                )
                .padding(16).background(Color.risoPaper)
            }
        }
        assertSnapshot(
            of: Host(tasks: pool),
            as: .image(layout: .fixed(width: 393, height: 320), traits: dark(false)), record: recordMode
        )
    }

    // MARK: - C3

    private func markGrid() -> some View {
        let cells: [(String, TaskType, Bool, Bool)] = [
            ("Read Dune", .normal, false, true),          // Simple counts toward
            ("Run 5 km", .counting, false, false),
            ("Weekend reading block", .compound, false, true), // Compound counts toward
            ("Visit the library", .normal, false, false),
            ("FREE", .normal, false, false),
            ("Book club", .normal, true, true),           // done: mark hidden
            ("Stretch", .normal, false, false),
            ("Push-ups", .counting, false, true),         // linked counter
            ("Journal", .normal, false, false),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(113), spacing: 6), count: 3), spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                if c.0 == "FREE" {
                    RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true)
                } else if c.1 == .compound {
                    RisoBoardPlayCell(title: c.0, taskType: .compound, isCompleted: c.2, isSharedCounter: c.3, compoundDoneCount: 1, compoundChildCount: 3)
                } else if c.1 == .counting {
                    RisoBoardPlayCell(title: c.0, taskType: .counting, isCompleted: c.2, currentCount: 3, maxCount: 5, isSharedCounter: c.3)
                } else {
                    RisoBoardPlayCell(title: c.0, taskType: .normal, isCompleted: c.2, isSharedCounter: c.3)
                }
            }
        }
        .frame(width: 3 * 113 + 12)
        .padding(12)
        .background(Color.risoPaper)
    }

    func testBoardCellMarkLight() {
        assertSnapshot(of: markGrid(), as: .image(layout: .fixed(width: 375, height: 375), traits: dark(false)), record: recordMode)
    }

    func testBoardCellMarkDark() {
        assertSnapshot(of: markGrid(), as: .image(layout: .fixed(width: 375, height: 375), traits: dark(true)), record: recordMode)
    }
}
