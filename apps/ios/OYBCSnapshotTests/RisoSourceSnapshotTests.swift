import SnapshotTesting
import SwiftUI
import XCTest
@testable import OYBC

/// Board Sources P2 — visual baselines for the new source-row +
/// source-picker components (docs/BOARD_SOURCES.md §Surfaces items 1–2;
/// handoff frames 2a/2c/4a/5c).
final class RisoSourceSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Fixtures

    private func makeTask(_ id: String, _ title: String, type: TaskType = .normal) -> OYBC.Task {
        SnapshotFixtures.makeTask(id: id, title: title, type: type)
    }

    private var taskById: [String: OYBC.Task] {
        [
            "t1": makeTask("t1", "Meditate 10 min"),
            "t2": makeTask("t2", "Read a chapter", type: .counting),
            "t3": makeTask("t3", "Morning routine", type: .compound),
            "t4": makeTask("t4", "Stretch"),
        ]
    }

    private func sourceRow(
        kind: BoardSource.Kind,
        min: Int = 0,
        max: Int? = nil,
        excluded: [String] = [],
        filter: BoardSource.Filter = .all,
        supply: [String] = ["t1", "t2", "t3", "t4"],
        done: Set<String> = [],
        expanded: Bool
    ) -> some View {
        var source = BoardSource(sourceId: "s1", kind: kind)
        source.min = min
        source.max = max
        source.excludedTaskIds = excluded
        source.filter = filter
        return RisoSourceRowView(
            source: source,
            supply: WizardSourceSupply(
                displayName: kind == .pool ? "Morning Kickstart" : "Weekday Core",
                rawSupplyTaskIds: supply,
                doneTaskIds: done
            ),
            availableCount: supply.filter { !excluded.contains($0) }
                .filter { !(kind == .board && filter == .todo && done.contains($0)) }.count,
            isExpanded: expanded,
            taskById: taskById,
            onToggleExpanded: {},
            onRemove: {},
            onSetFilter: { _ in },
            onSetRange: { _, _ in },
            onToggleExclude: { _ in }
        )
        .padding(20)
        .background(Color.risoPaper)
    }

    // MARK: - Collapsed rows

    func testPoolRowCollapsedLight() {
        assertSnapshot(
            of: sourceRow(kind: .pool, expanded: false),
            as: .image(layout: .fixed(width: 393, height: 100)),
            record: recordMode
        )
    }

    func testPoolRowCollapsedRangeAndExcludeSubtitleLight() {
        assertSnapshot(
            of: sourceRow(kind: .pool, min: 1, max: 2, excluded: ["t4"], expanded: false),
            as: .image(layout: .fixed(width: 393, height: 100)),
            record: recordMode
        )
    }

    func testBoardRowCollapsedLight() {
        assertSnapshot(
            of: sourceRow(kind: .board, done: ["t1", "t2"], expanded: false),
            as: .image(layout: .fixed(width: 393, height: 100)),
            record: recordMode
        )
    }

    func testBoardRowCollapsedDark() {
        assertSnapshot(
            of: sourceRow(kind: .board, done: ["t1", "t2"], expanded: false),
            as: .image(
                layout: .fixed(width: 393, height: 100),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Expanded panels

    func testPoolRowExpandedRangeAndUndoLight() {
        assertSnapshot(
            of: sourceRow(kind: .pool, min: 1, max: 2, excluded: ["t2"], expanded: true),
            as: .image(layout: .fixed(width: 393, height: 460)),
            record: recordMode
        )
    }

    func testPoolRowExpandedRangeAndUndoDark() {
        assertSnapshot(
            of: sourceRow(kind: .pool, min: 1, max: 2, excluded: ["t2"], expanded: true),
            as: .image(
                layout: .fixed(width: 393, height: 460),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    func testBoardRowExpandedTodoFilterLight() {
        assertSnapshot(
            of: sourceRow(kind: .board, filter: .todo, done: ["t1", "t3"], expanded: true),
            as: .image(layout: .fixed(width: 393, height: 520)),
            record: recordMode
        )
    }

    /// Slider at scale (frame 4a): 25 stops → ticks + sparse labels.
    func testPoolRowExpandedLargeSupplyLight() {
        let bigSupply = (1...25).map { "big-\($0)" }
        var big = taskById
        for id in bigSupply { big[id] = makeTask(id, "Task \(id)") }
        var source = BoardSource(sourceId: "s1", kind: .pool)
        source.min = 5
        source.max = 20
        let view = RisoSourceRowView(
            source: source,
            supply: WizardSourceSupply(
                displayName: "Everything pool",
                rawSupplyTaskIds: bigSupply,
                doneTaskIds: []
            ),
            availableCount: 25,
            isExpanded: true,
            taskById: big,
            onToggleExpanded: {},
            onRemove: {},
            onSetFilter: { _ in },
            onSetRange: { _, _ in },
            onToggleExclude: { _ in }
        )
        .padding(20)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 400)),
            record: recordMode
        )
    }

    // MARK: - Source picker sheet

    private func sheet(
        pools: [Pool],
        boards: [RisoSourcePickerSheetView.BoardEntry],
        pulled: Set<String>
    ) -> some View {
        RisoSourcePickerSheetView(
            pools: pools,
            boards: boards,
            pulledSourceIds: pulled,
            onTogglePool: { _ in },
            onToggleBoard: { _ in }
        )
        .frame(width: 393, height: 620)
    }

    func testSourceSheetPopulatedLight() {
        let pools = [
            SnapshotFixtures.makeTestPool(id: "p1", name: "Morning Kickstart", taskIds: ["t1", "t2"]),
            SnapshotFixtures.makeTestPool(id: "p2", name: "Evening wind-down", taskIds: ["t3"]),
        ]
        let boards = [
            RisoSourcePickerSheetView.BoardEntry(
                board: SnapshotFixtures.makeBoard(id: "b1", name: "Weekday Core"),
                squares: 8,
                done: 3
            ),
        ]
        assertSnapshot(
            of: sheet(pools: pools, boards: boards, pulled: ["p1"]),
            as: .image(layout: .fixed(width: 393, height: 620)),
            record: recordMode
        )
    }

    func testSourceSheetPopulatedDark() {
        let pools = [
            SnapshotFixtures.makeTestPool(id: "p1", name: "Morning Kickstart", taskIds: ["t1", "t2"]),
        ]
        let boards = [
            RisoSourcePickerSheetView.BoardEntry(
                board: SnapshotFixtures.makeBoard(id: "b1", name: "Weekday Core"),
                squares: 8,
                done: 3
            ),
        ]
        assertSnapshot(
            of: sheet(pools: pools, boards: boards, pulled: ["b1"]),
            as: .image(
                layout: .fixed(width: 393, height: 620),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    func testSourceSheetEmptyStateLight() {
        assertSnapshot(
            of: sheet(pools: [], boards: [], pulled: []),
            as: .image(layout: .fixed(width: 393, height: 620)),
            record: recordMode
        )
    }
}
