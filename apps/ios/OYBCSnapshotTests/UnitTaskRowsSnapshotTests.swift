import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Unit tasks PR 2 (handoff frames C8-C12, D3): the dense counter `UnitTagView`
/// leading every task row's subtitle slot — Tasks tab, Library sheet, quick-add
/// match rows, the pool list — and Task Detail's "Counter" row. Pure props.
final class UnitTaskRowsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func traits(_ dark: Bool) -> UITraitCollection { .init(userInterfaceStyle: dark ? .dark : .light) }

    // MARK: - Fixtures

    private let counter = "ct-books"

    private func counterRoot() -> Task {
        SnapshotFixtures.makeTask(id: counter, title: "Read 12 books", type: .counting, action: "Read",
                                  unit: "books", maxCount: 12, isCounter: true, counterName: "Books")
    }

    private func unit(_ id: String, _ title: String, _ type: TaskType, maxCount: CountValue? = nil, unitWord: String? = nil) -> Task {
        var t = SnapshotFixtures.makeTask(
            id: id, title: title, type: type, action: type == .counting ? "Read" : nil,
            unit: unitWord, maxCount: maxCount, operatorType: type == .compound ? .and : nil
        )
        t.countsTowardCounterId = counter
        return t
    }

    /// The linked copy: a Counting task whose goal is in the counter's unit.
    private func copy() -> Task {
        var t = SnapshotFixtures.makeTask(id: "cp", title: "Read 2 books", type: .counting, action: "Read", unit: "books", maxCount: 2)
        t.sharedCounterId = counter
        return t
    }

    private func tasksTabRows(dark: Bool) -> some View {
        let tag = "Books"
        func row(_ t: Task, children: Int = 0, root: Bool = false, tagged: Bool = true) -> some View {
            RisoTaskRowView(
                task: t, placementCount: 1, activePlacementCount: 1, childCount: children,
                isFamilyRoot: root, counterTagName: tagged ? tag : nil
            )
        }
        return ZStack {
            RisoPaperBackground()
            VStack(spacing: 8) {
                row(unit("u1", "Read 300 pages", .counting, maxCount: 300, unitWord: "pages"))
                row(unit("u3", "Finish Dune", .normal))
                row(unit("u4", "Book club night", .compound), children: 0)
                row(unit("u2", "Finish the audiobook", .compound), children: 2)
                row(counterRoot(), root: true, tagged: false)
                row(SnapshotFixtures.makeTask(id: "w", title: "Walk the dog", type: .normal), tagged: false)
            }
            .padding(12)
        }
    }

    func testTasksTabRowsLight() {
        assertSnapshot(of: tasksTabRows(dark: false), as: .image(layout: .fixed(width: 393, height: 470), traits: traits(false)), record: recordMode)
    }

    func testTasksTabRowsDark() {
        assertSnapshot(of: tasksTabRows(dark: true), as: .image(layout: .fixed(width: 393, height: 470), traits: traits(true)), record: recordMode)
    }

    // MARK: - Library sheet rows

    private func libraryRows() -> some View {
        func card(_ label: RisoLibraryRowLabel, added: Bool) -> some View {
            label
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        }
        func label(_ title: String, _ kind: RisoTaskKind, tag: String?, sub: String?, usage: String, added: Bool, compound: Bool = false) -> RisoLibraryRowLabel {
            .init(title: title, kind: kind, counterTagName: tag, subtitle: sub, usageText: usage,
                  isAdded: added, isCompound: compound, isExpanded: false)
        }
        return ZStack {
            RisoPaperBackground()
            VStack(spacing: 7) {
                card(label("Finish Dune", .normal, tag: "Books", sub: nil, usage: "1 bd", added: true), added: true)
                card(label("Read 300 pages", .counting, tag: "Books", sub: TaskCountDisplay.goalSubtitle(for: unit("u1", "Read 300 pages", .counting, maxCount: 300, unitWord: "pages")), usage: "1 bd", added: false), added: false)
                card(label("Book club night", .compound, tag: "Books", sub: nil, usage: "0 bds", added: true, compound: true), added: true)
                card(label("Walk the dog", .normal, tag: nil, sub: nil, usage: "2 bds", added: false), added: false)
            }
            .padding(16)
        }
    }

    func testLibraryRowsLight() {
        assertSnapshot(of: libraryRows(), as: .image(layout: .fixed(width: 393, height: 250), traits: traits(false)), record: recordMode)
    }

    func testLibraryRowsDark() {
        assertSnapshot(of: libraryRows(), as: .image(layout: .fixed(width: 393, height: 250), traits: traits(true)), record: recordMode)
    }

    // MARK: - Quick-add match rows

    private func quickAdd(seed: String, dark: Bool) -> some View {
        let pool: [Task] = [
            counterRoot(),
            unit("u3", "Finish Dune", .normal),
            unit("u1", "Read 300 pages", .counting, maxCount: 300, unitWord: "pages"),
            SnapshotFixtures.makeTask(id: "w", title: "Walk the dog", type: .normal),
        ]
        return ZStack {
            RisoPaperBackground()
            RisoQuickAddRowView(
                userId: SnapshotFixtures.userId, defaultStartDate: nil, defaultEndDate: nil,
                onTaskCreated: { _, _, _ in }, onPendingCreated: nil, onLibraryReloadRequested: {},
                libraryTasks: pool, selectedIds: [], onExistingTaskPicked: { _ in },
                placementTimeframe: .weekly, seedText: seed
            )
            .padding(Riso.gutter)
        }
    }

    func testQuickAddDuneLight() {
        assertSnapshot(of: quickAdd(seed: "Dune", dark: false), as: .image(layout: .fixed(width: 393, height: 150), traits: traits(false)), record: recordMode)
    }

    func testQuickAddBooksLight() {
        assertSnapshot(of: quickAdd(seed: "Books", dark: false), as: .image(layout: .fixed(width: 393, height: 230), traits: traits(false)), record: recordMode)
    }

    func testQuickAddBooksDark() {
        assertSnapshot(of: quickAdd(seed: "Books", dark: true), as: .image(layout: .fixed(width: 393, height: 230), traits: traits(true)), record: recordMode)
    }

    // MARK: - Pool list row

    private func poolList() -> some View {
        let tasks = [unit("u3", "Finish Dune", .normal), unit("u1", "Read 300 pages", .counting, maxCount: 300, unitWord: "pages"),
                     SnapshotFixtures.makeTask(id: "w", title: "Walk the dog", type: .normal)]
        let byId = Dictionary(uniqueKeysWithValues: (tasks + [counterRoot()]).map { ($0.id, $0) })
        return RisoPoolListView(
            selectedTaskIds: Set(tasks.map(\.id)), orderedTaskIds: tasks.map(\.id),
            effectiveTaskById: byId, effectiveChildrenByCompound: [:], isRecurring: false, onRemove: { _ in }
        )
        .padding(20)
        .background(Color.risoPaper)
    }

    func testPoolListUnitRowsLight() {
        assertSnapshot(of: poolList(), as: .image(layout: .fixed(width: 393, height: 250), traits: traits(false)), record: recordMode)
    }

    // MARK: - Task Detail "Counter" row

    private func detail(dark: Bool) -> some View {
        RisoTaskDetailContentView(
            task: unit("u3", "Finish Dune", .normal),
            placements: [], affectedBoards: [], parentCompounds: [], compoundChildren: [], templates: [],
            now: SnapshotFixtures.fixedNow,
            onEditSubmit: { _ in }, onDeleteTap: {}, onOpenTask: { _ in }, onOpenBoard: { _ in },
            counterSourceOverride: LinkedCounterSource(title: "Books", lifetime: 12, unit: "books", kind: .discrete)
        )
        .frame(width: 393, height: 520)
    }

    func testDetailCounterRowLight() {
        assertSnapshot(of: detail(dark: false), as: .image(layout: .fixed(width: 393, height: 520), traits: traits(false)), record: recordMode)
    }

    func testDetailCounterRowDark() {
        assertSnapshot(of: detail(dark: true), as: .image(layout: .fixed(width: 393, height: 520), traits: traits(true)), record: recordMode)
    }
}
