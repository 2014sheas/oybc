import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Unit tasks (docs/SHARED_COUNTER_SETTINGS.md §3d, handoff `design_handoff_unit_tasks`):
/// the `UnitTagView` kit piece, the Counter Detail "Unit tasks" section
/// (frames A7 / A8 / A12 / A13), the counter-delete confirm's new line (A11)
/// and the "+ New" sheet's counter identity (B7 / B8 / B9). Pure props
/// throughout (no `AppDatabase.shared`). The remove alert is system UI.
final class UnitTasksSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func dark(_ on: Bool) -> UITraitCollection { .init(userInterfaceStyle: on ? .dark : .light) }

    // MARK: - UnitTag

    private func tags() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                UnitTagView(name: "Books", dense: true)
                UnitTagView(name: "Books")
            }
            UnitTagView(name: "Pages read this very long counter name", dense: true)
            KindTagView(kind: .discrete, dense: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.risoPaper)
    }

    func testUnitTagLight() {
        assertSnapshot(of: tags(), as: .image(layout: .fixed(width: 393, height: 130), traits: dark(false)), record: recordMode)
    }

    func testUnitTagDark() {
        assertSnapshot(of: tags(), as: .image(layout: .fixed(width: 393, height: 130), traits: dark(true)), record: recordMode)
    }

    // MARK: - Section fixtures

    private func unit(_ id: String, _ title: String, type: TaskType, maxCount: CountValue? = nil) -> Task {
        var t = SnapshotFixtures.makeTask(
            id: id, title: title, type: type, action: type == .counting ? "Read" : nil,
            unit: type == .counting ? "pages" : nil, maxCount: maxCount,
            operatorType: type == .compound ? .and : nil
        )
        t.countsTowardCounterId = "ct-books"
        return t
    }

    private func row(
        _ id: String, _ status: CountsToward.ContributorRowStatus, board: String?, credits: Int = 0, at: String? = nil,
        progress: CountsToward.Progress? = nil, child: CountsToward.ChildProgress? = nil
    ) -> CountsToward.ContributorRow {
        .init(taskId: id, status: status, boardId: board, creditCount: credits, latestOccurredAt: at,
              progress: progress, childProgress: child)
    }

    /// The handoff's six: Counting mid-progress, Compound 1 of 2, Simple, zero-subtask Compound, a repeating "× 4", a done Simple.
    private func sixUnitTasks(extra: [(Task, CountsToward.ContributorRow)] = []) -> CountsTowardSectionData {
        // The kernel's order: In progress, Not started, Done — each by title (Done by recency).
        var pairs: [(Task, CountsToward.ContributorRow)] = [
            (unit("u2", "Finish the audiobook", type: .compound),
             row("u2", .inProgress, board: "by", child: .init(done: 1, total: 2))),
            (unit("u1", "Read 300 pages", type: .counting, maxCount: 300),
             row("u1", .inProgress, board: "bm", progress: .init(current: 120, goal: 300, kind: .discrete))),
            (unit("u4", "Book club night", type: .compound), row("u4", .notStarted, board: nil, child: .init(done: 0, total: 0))),
            (unit("u3", "Finish Dune", type: .normal), row("u3", .notStarted, board: "bw")),
        ]
        pairs += extra
        pairs += [
            (unit("u5", "Read before bed", type: .normal), row("u5", .done, board: "bh", credits: 4, at: "2026-10-09T09:00:00.000Z")),
            (unit("u6", "Finish Project Hail Mary", type: .normal), row("u6", .done, board: "bm", at: "2026-10-07T09:00:00.000Z")),
        ]
        let boards = [
            SnapshotFixtures.makeBoard(id: "bm", name: "October reading", timeframe: .monthly),
            SnapshotFixtures.makeBoard(id: "by", name: "2026", timeframe: .yearly),
            SnapshotFixtures.makeBoard(id: "bw", name: "This week", timeframe: .weekly),
            SnapshotFixtures.makeBoard(id: "bh", name: "Weekly habits", timeframe: .weekly),
        ]
        return CountsTowardSectionData(
            counterName: "Books", rows: pairs.map(\.1),
            taskById: Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, $0.0) }),
            boardById: Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })
        )
    }

    private func section(_ data: CountsTowardSectionData, highlight: String? = nil, openSwipe: String? = nil) -> some View {
        CountsTowardSectionView(data: data, highlightedTaskId: highlight, openSwipeSeed: openSwipe)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.risoPaper)
    }

    // MARK: - Section

    func testSectionListLight() {
        assertSnapshot(of: section(sixUnitTasks()), as: .image(layout: .fixed(width: 393, height: 480), traits: dark(false)), record: recordMode)
    }

    func testSectionListDark() {
        assertSnapshot(of: section(sixUnitTasks()), as: .image(layout: .fixed(width: 393, height: 480), traits: dark(true)), record: recordMode)
    }

    func testSectionEmptyLight() {
        let empty = CountsTowardSectionData(counterName: "Books", rows: [], taskById: [:], boardById: [:])
        assertSnapshot(of: section(empty), as: .image(layout: .fixed(width: 393, height: 150), traits: dark(false)), record: recordMode)
    }

    /// A12: the row "+ New" just made, with the 3pt gold ring.
    func testSectionReturnRingLight() {
        let arrived = (unit("u7", "Finish Piranesi", type: .normal), row("u7", .notStarted, board: nil))
        assertSnapshot(
            of: section(sixUnitTasks(extra: [arrived]), highlight: "u7"),
            as: .image(layout: .fixed(width: 393, height: 550), traits: dark(false)), record: recordMode
        )
    }

    func testSectionReturnRingDark() {
        let arrived = (unit("u7", "Finish Piranesi", type: .normal), row("u7", .notStarted, board: nil))
        assertSnapshot(
            of: section(sixUnitTasks(extra: [arrived]), highlight: "u7"),
            as: .image(layout: .fixed(width: 393, height: 550), traits: dark(true)), record: recordMode
        )
    }

    /// A9: a row swiped open — the red Remove fills the card's height.
    func testSectionSwipeOpenLight() {
        assertSnapshot(of: section(sixUnitTasks(), openSwipe: "u3"), as: .image(layout: .fixed(width: 393, height: 480), traits: dark(false)), record: recordMode)
    }

    // MARK: - Counter delete confirm (A11)

    private func deleteConfirm(unitTasks: Int) -> some View {
        let now = "2026-02-01T00:00:00.000"
        let member = Task(
            id: "m1", userId: "u1", title: "Read 12 books", type: .counting, action: "Read", unit: "books",
            totalCompletions: 0, totalInstances: 0, currentCount: 12, createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        let src = SharedCounterMemberTask(
            boardTaskId: "bt-m1-b1", taskId: "m1", taskTitle: "Read 12 books", isSource: false, boardId: "b1", boardName: "2026",
            timeframe: .yearly, window: "2026", goal: 12, logged: 12, met: true, over: 0, isActive: true, viaCompoundId: nil
        )
        let group = SharedCounterGroup(
            counterId: "ct-books", name: "Books", action: "Read", unit: "books", lifetime: 12,
            tasks: [src], taskCount: 1, boardCount: 1, activeTaskCount: 1
        )
        let impact = AppDatabase.TaskDeletionImpact(
            boardTaskCount: 0, affectedBoardIds: [], affectedBoards: [], childLinkCount: 0, parentLinkCount: 0,
            counterMemberCount: 1, counterMembers: [member], derivedWindowCounterCount: 0, unitTaskCount: unitTasks
        )
        return CounterDeleteConfirmView(group: group, impact: impact, onConfirm: {}, onCancel: {})
    }

    func testDeleteConfirmUnitTasksLight() {
        assertSnapshot(of: deleteConfirm(unitTasks: 6), as: .image(layout: .fixed(width: 393, height: 480), traits: dark(false)), record: recordMode)
    }

    func testDeleteConfirmUnitTasksDark() {
        assertSnapshot(of: deleteConfirm(unitTasks: 1), as: .image(layout: .fixed(width: 393, height: 480), traits: dark(true)), record: recordMode)
    }

    // MARK: - "+ New" from a counter (B7 / B8 / B9)

    private func sheet(startOn: RisoSpecialTaskPanel.SpecialType, seed: RisoSpecialTaskPanel.CountingSeed? = nil, library: [Task] = [], preset: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            NewTaskSheetTitle(counterName: "Books").frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                Text("Special type").risoSectionLabel()
                RisoSpecialTaskPanel(
                    userId: SnapshotFixtures.userId, defaultStartDate: nil, defaultEndDate: nil,
                    taskLibrary: library,
                    onTaskCreated: { _, _, _ in }, onCompoundCreated: { _ in }, onPendingCreated: nil,
                    onLibraryReloadRequested: {}, submitLabel: CountsTowardLabels.submitLabel,
                    countingSeed: seed, startExpandedOn: seed == nil ? startOn : nil,
                    presetCountsTowardCounterId: preset ? "ct-books" : nil
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.risoPaper)
    }

    private var countingSeed: RisoSpecialTaskPanel.CountingSeed {
        .init(action: "Read", goal: "300", unit: "pages", kind: .discrete)
    }

    func testNewSheetCountingLight() {
        assertSnapshot(of: sheet(startOn: .counting, seed: countingSeed), as: .image(layout: .fixed(width: 393, height: 520), traits: dark(false)), record: recordMode)
    }

    func testNewSheetCountingDark() {
        assertSnapshot(of: sheet(startOn: .counting, seed: countingSeed), as: .image(layout: .fixed(width: 393, height: 520), traits: dark(true)), record: recordMode)
    }

    /// A library counter that matches the typed pair: without the preset the auto-link hint would mount here.
    func testNewSheetCountingMatchingCounterShowsNoLinkHint() {
        let counter = SnapshotFixtures.makeTask(
            id: "ct-books", title: "Read 12 books", type: .counting, action: "Read", unit: "books", maxCount: 12,
            isCounter: true, counterName: "Books"
        )
        let seed = RisoSpecialTaskPanel.CountingSeed(action: "Read", goal: "300", unit: "books", kind: .discrete)
        assertSnapshot(of: sheet(startOn: .counting, seed: seed, library: [counter]), as: .image(layout: .fixed(width: 393, height: 520), traits: dark(false)), record: recordMode)
    }

    /// The contrast: the same matching library counter WITHOUT the preset mounts the auto-link hint.
    func testNewSheetCountingMatchingCounterWithoutPresetShowsLinkHint() {
        let counter = SnapshotFixtures.makeTask(
            id: "ct-books", title: "Read 12 books", type: .counting, action: "Read", unit: "books", maxCount: 12,
            isCounter: true, counterName: "Books"
        )
        let seed = RisoSpecialTaskPanel.CountingSeed(action: "Read", goal: "300", unit: "books", kind: .discrete)
        assertSnapshot(of: sheet(startOn: .counting, seed: seed, library: [counter], preset: false), as: .image(layout: .fixed(width: 393, height: 560), traits: dark(false)), record: recordMode)
    }

    func testNewSheetCompoundLight() {
        assertSnapshot(of: sheet(startOn: .compound), as: .image(layout: .fixed(width: 393, height: 520), traits: dark(false)), record: recordMode)
    }

    func testNewSheetCompoundDark() {
        assertSnapshot(of: sheet(startOn: .compound), as: .image(layout: .fixed(width: 393, height: 520), traits: dark(true)), record: recordMode)
    }
}
