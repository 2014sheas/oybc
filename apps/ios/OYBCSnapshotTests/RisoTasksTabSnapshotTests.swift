import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Riso Tasks-tab reskin (Phase 4).
///
/// Snapshots the leaf presentational components with injected fixtures:
///   - `RisoTaskRowView` for each task type (Normal, Counting, Compound,
///     Achievement) in light + dark.
///   - `RisoCompoundGroupRowView` collapsed + expanded in light + dark.
///   - `RisoTasksControlsView` (header controls) in light + dark.
///   - Tasks-tab header + Library/Pools pill segment (P2 Task 3) in
///     light + dark — see `TasksTabHeaderSegmentPreview` below.
///   - `RisoTaskDetailContentView` for a Normal task in light + dark.
///
/// All timestamps are pinned via `SnapshotFixtures.fixedTimestamp` so
/// renders stay deterministic across machines and days.
///
/// `TasksTabView` self-loads from `AppDatabase.shared` and is excluded
/// from snapshot coverage here (the existing `AppDatabase.shared`
/// constraint applies — seed an in-memory DB test instance when a full
/// tab snapshot becomes needed).
final class RisoTasksTabSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Helpers

    private func lightTraits() -> UITraitCollection {
        UITraitCollection(userInterfaceStyle: .light)
    }

    private func darkTraits() -> UITraitCollection {
        UITraitCollection(userInterfaceStyle: .dark)
    }

    /// Wrap a view in RisoPaperBackground at the given fixed size.
    private func wrap<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RisoPaperBackground()
            view.padding(12)
        }
        .frame(width: width, height: height)
    }

    // MARK: - RisoTaskRowView — Normal

    func testRowNormalLight() {
        let task = SnapshotFixtures.makeTask(id: "t-n", title: "Meditate 10 min", type: .normal)
        let view = wrap(
            RisoTaskRowView(task: task, placementCount: 4, activePlacementCount: 3, childCount: 0),
            width: 353, height: 72
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 72), traits: lightTraits()),
            record: recordMode
        )
    }

    func testRowNormalDark() {
        let task = SnapshotFixtures.makeTask(id: "t-n", title: "Meditate 10 min", type: .normal)
        let view = wrap(
            RisoTaskRowView(task: task, placementCount: 4, activePlacementCount: 3, childCount: 0),
            width: 353, height: 72
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 72), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - RisoTaskRowView — Counting

    func testRowCountingLight() {
        let task = SnapshotFixtures.makeTask(
            id: "t-c", title: "Drink water", type: .counting,
            action: "Drink", unit: "cups", maxCount: 8
        )
        let view = wrap(
            RisoTaskRowView(task: task, placementCount: 3, activePlacementCount: 2, childCount: 0),
            width: 353, height: 80
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 80), traits: lightTraits()),
            record: recordMode
        )
    }

    func testRowCountingDark() {
        let task = SnapshotFixtures.makeTask(
            id: "t-c", title: "Drink water", type: .counting,
            action: "Drink", unit: "cups", maxCount: 8
        )
        let view = wrap(
            RisoTaskRowView(task: task, placementCount: 3, activePlacementCount: 2, childCount: 0),
            width: 353, height: 80
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 80), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - RisoTaskRowView — Compound

    func testRowCompoundLight() {
        let task = SnapshotFixtures.makeTask(
            id: "t-k", title: "Morning routine", type: .compound,
            operatorType: .and, isOrdered: false
        )
        let view = wrap(
            RisoTaskRowView(task: task, placementCount: 2, activePlacementCount: 1, childCount: 3),
            width: 353, height: 80
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 80), traits: lightTraits()),
            record: recordMode
        )
    }

    func testRowCompoundDark() {
        let task = SnapshotFixtures.makeTask(
            id: "t-k", title: "Morning routine", type: .compound,
            operatorType: .and, isOrdered: false
        )
        let view = wrap(
            RisoTaskRowView(task: task, placementCount: 2, activePlacementCount: 1, childCount: 3),
            width: 353, height: 80
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 80), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - RisoTaskRowView — Achievement

    func testRowAchievementLight() {
        var task = SnapshotFixtures.makeTask(id: "t-a", title: "GREENLOG a board", type: .achievement)
        task.achievementTrigger = .greenlog
        let view = wrap(
            RisoTaskRowView(task: task, placementCount: 1, activePlacementCount: 1, childCount: 0),
            width: 353, height: 80
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 80), traits: lightTraits()),
            record: recordMode
        )
    }

    func testRowAchievementDark() {
        var task = SnapshotFixtures.makeTask(id: "t-a", title: "GREENLOG a board", type: .achievement)
        task.achievementTrigger = .greenlog
        let view = wrap(
            RisoTaskRowView(task: task, placementCount: 1, activePlacementCount: 1, childCount: 0),
            width: 353, height: 80
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 80), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - RisoCompoundGroupRowView — Collapsed

    func testCompoundGroupCollapsedLight() {
        let parent = SnapshotFixtures.makeTask(
            id: "t-compound-and", title: "Daily wellness", type: .compound,
            operatorType: .and, isOrdered: false
        )
        let children: [(link: CompoundChild, task: Task?)] = [
            (link: SnapshotFixtures.makeCompoundChild(id: "cc1", compoundTaskId: parent.id, childTaskId: "t-leaf-water", childIndex: 0),
             task: SnapshotFixtures.makeTask(id: "t-leaf-water", title: "Drink water", type: .normal)),
            (link: SnapshotFixtures.makeCompoundChild(id: "cc2", compoundTaskId: parent.id, childTaskId: "t-leaf-stretch", childIndex: 1),
             task: SnapshotFixtures.makeTask(id: "t-leaf-stretch", title: "Stretch 5 min", type: .normal)),
        ]
        let view = wrap(
            RisoCompoundGroupRowView(
                task: parent,
                placementCount: 2,
                activePlacementCount: 1,
                childCount: 2,
                isExpandable: true,
                isExpanded: false,
                onToggleExpand: {},
                children: children,
                childPlacementCounts: [:],
                childActivePlacementCounts: [:],
                onChildTap: { _ in }
            ),
            width: 353, height: 72
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 72), traits: lightTraits()),
            record: recordMode
        )
    }

    func testCompoundGroupCollapsedDark() {
        let parent = SnapshotFixtures.makeTask(
            id: "t-compound-and", title: "Daily wellness", type: .compound,
            operatorType: .and, isOrdered: false
        )
        let children: [(link: CompoundChild, task: Task?)] = [
            (link: SnapshotFixtures.makeCompoundChild(id: "cc1", compoundTaskId: parent.id, childTaskId: "t-leaf-water", childIndex: 0),
             task: SnapshotFixtures.makeTask(id: "t-leaf-water", title: "Drink water", type: .normal)),
        ]
        let view = wrap(
            RisoCompoundGroupRowView(
                task: parent,
                placementCount: 2,
                activePlacementCount: 1,
                childCount: 2,
                isExpandable: true,
                isExpanded: false,
                onToggleExpand: {},
                children: children,
                childPlacementCounts: [:],
                childActivePlacementCounts: [:],
                onChildTap: { _ in }
            ),
            width: 353, height: 72
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 72), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - RisoCompoundGroupRowView — Expanded

    func testCompoundGroupExpandedLight() {
        let parent = SnapshotFixtures.makeTask(
            id: "t-compound-and", title: "Daily wellness", type: .compound,
            operatorType: .and, isOrdered: false
        )
        let children: [(link: CompoundChild, task: Task?)] = [
            (link: SnapshotFixtures.makeCompoundChild(id: "cc1", compoundTaskId: parent.id, childTaskId: "t-leaf-water", childIndex: 0),
             task: SnapshotFixtures.makeTask(id: "t-leaf-water", title: "Drink water", type: .normal)),
            (link: SnapshotFixtures.makeCompoundChild(id: "cc2", compoundTaskId: parent.id, childTaskId: "t-leaf-stretch", childIndex: 1),
             task: SnapshotFixtures.makeTask(id: "t-leaf-stretch", title: "Stretch 5 min", type: .normal)),
            (link: SnapshotFixtures.makeCompoundChild(id: "cc3", compoundTaskId: parent.id, childTaskId: "t-leaf-vitamins", childIndex: 2),
             task: SnapshotFixtures.makeTask(id: "t-leaf-vitamins", title: "Take vitamins", type: .normal)),
        ]
        let view = wrap(
            RisoCompoundGroupRowView(
                task: parent,
                placementCount: 2,
                activePlacementCount: 1,
                childCount: 3,
                isExpandable: true,
                isExpanded: true,
                onToggleExpand: {},
                children: children,
                childPlacementCounts: ["t-leaf-water": 1],
                childActivePlacementCounts: ["t-leaf-water": 1],
                onChildTap: { _ in }
            ),
            width: 353, height: 260
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 260), traits: lightTraits()),
            record: recordMode
        )
    }

    func testCompoundGroupExpandedDark() {
        let parent = SnapshotFixtures.makeTask(
            id: "t-compound-and", title: "Daily wellness", type: .compound,
            operatorType: .and, isOrdered: false
        )
        let children: [(link: CompoundChild, task: Task?)] = [
            (link: SnapshotFixtures.makeCompoundChild(id: "cc1", compoundTaskId: parent.id, childTaskId: "t-leaf-water", childIndex: 0),
             task: SnapshotFixtures.makeTask(id: "t-leaf-water", title: "Drink water", type: .normal)),
            (link: SnapshotFixtures.makeCompoundChild(id: "cc2", compoundTaskId: parent.id, childTaskId: "t-leaf-stretch", childIndex: 1),
             task: SnapshotFixtures.makeTask(id: "t-leaf-stretch", title: "Stretch 5 min", type: .normal)),
            (link: SnapshotFixtures.makeCompoundChild(id: "cc3", compoundTaskId: parent.id, childTaskId: "t-leaf-vitamins", childIndex: 2),
             task: SnapshotFixtures.makeTask(id: "t-leaf-vitamins", title: "Take vitamins", type: .normal)),
        ]
        let view = wrap(
            RisoCompoundGroupRowView(
                task: parent,
                placementCount: 2,
                activePlacementCount: 1,
                childCount: 3,
                isExpandable: true,
                isExpanded: true,
                onToggleExpand: {},
                children: children,
                childPlacementCounts: ["t-leaf-water": 1],
                childActivePlacementCounts: ["t-leaf-water": 1],
                onChildTap: { _ in }
            ),
            width: 353, height: 260
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 260), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - RisoTasksControlsView

    func testControlsDefaultLight() {
        let view = controlsView(typeFilter: .all, sortBy: .updatedDesc, resultCount: 20)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 200), traits: lightTraits()),
            record: recordMode
        )
    }

    func testControlsDefaultDark() {
        let view = controlsView(typeFilter: .all, sortBy: .updatedDesc, resultCount: 20)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 200), traits: darkTraits()),
            record: recordMode
        )
    }

    func testControlsCountingFilterLight() {
        let view = controlsView(typeFilter: .counting, sortBy: .mostUsedDesc, resultCount: 3)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 200), traits: lightTraits()),
            record: recordMode
        )
    }

    func testControlsCountingFilterDark() {
        let view = controlsView(typeFilter: .counting, sortBy: .mostUsedDesc, resultCount: 3)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 200), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - Tasks-tab header + Pools segment (P2 Task 3)
    //
    // `TasksTabView` itself stays excluded (see the class doc above), but
    // its header composition — kicker "Your library" + H1 "Tasks" + the
    // new pill Library/Pools segment sitting above the controls block — is
    // DB-free UI, so it's reproduced here with the SAME production
    // modifiers/component (`.risoKicker()` / `.risoH1()` / `RisoSegmented`)
    // `TasksTabView.headerRow` / `.segmentRow` compose, guarding the
    // "sits above the controls block" placement from the handoff
    // screenshot `01-pools.png`.

    private func tasksTabHeaderWithSegment() -> some View {
        TasksTabHeaderSegmentPreview()
            .padding(Riso.gutter)
            .background(Color.risoPaper)
            .frame(width: 393, height: 140)
    }

    func testTasksTabHeaderWithSegmentLight() {
        assertSnapshot(
            of: tasksTabHeaderWithSegment(),
            as: .image(layout: .fixed(width: 393, height: 140), traits: lightTraits()),
            record: recordMode
        )
    }

    func testTasksTabHeaderWithSegmentDark() {
        assertSnapshot(
            of: tasksTabHeaderWithSegment(),
            as: .image(layout: .fixed(width: 393, height: 140), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - RisoTaskDetailContentView — Normal task

    func testDetailNormalLight() {
        let task = SnapshotFixtures.makeTask(id: "t-detail", title: "Meditate 10 min", type: .normal)
        let view = RisoTaskDetailContentView(
            task: task,
            placements: [],
            affectedBoards: [],
            parentCompounds: [],
            compoundChildren: [],
            templates: [],
            onEditSubmit: { _ in },
            onDeleteTap: {},
            onOpenTask: { _ in },
            onOpenBoard: { _ in }
        )
        .frame(width: 393, height: 520)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 520), traits: lightTraits()),
            record: recordMode
        )
    }

    func testDetailNormalDark() {
        let task = SnapshotFixtures.makeTask(id: "t-detail", title: "Meditate 10 min", type: .normal)
        let view = RisoTaskDetailContentView(
            task: task,
            placements: [],
            affectedBoards: [],
            parentCompounds: [],
            compoundChildren: [],
            templates: [],
            onEditSubmit: { _ in },
            onDeleteTap: {},
            onOpenTask: { _ in },
            onOpenBoard: { _ in }
        )
        .frame(width: 393, height: 520)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 520), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - RisoTaskDetailContentView — Compound task

    func testDetailCompoundLight() {
        let task = SnapshotFixtures.makeTask(
            id: "t-compound", title: "Daily wellness", type: .compound,
            operatorType: .and, isOrdered: false
        )
        let children = [
            SnapshotFixtures.makeTask(id: "t-leaf-water", title: "Drink water", type: .normal),
            SnapshotFixtures.makeTask(id: "t-leaf-stretch", title: "Stretch 5 min", type: .normal),
        ]
        let view = RisoTaskDetailContentView(
            task: task,
            placements: [],
            affectedBoards: [],
            parentCompounds: [],
            compoundChildren: children,
            templates: [],
            onEditSubmit: { _ in },
            onDeleteTap: {},
            onOpenTask: { _ in },
            onOpenBoard: { _ in }
        )
        .frame(width: 393, height: 600)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 600), traits: lightTraits()),
            record: recordMode
        )
    }

    func testDetailCompoundDark() {
        let task = SnapshotFixtures.makeTask(
            id: "t-compound", title: "Daily wellness", type: .compound,
            operatorType: .and, isOrdered: false
        )
        let children = [
            SnapshotFixtures.makeTask(id: "t-leaf-water", title: "Drink water", type: .normal),
            SnapshotFixtures.makeTask(id: "t-leaf-stretch", title: "Stretch 5 min", type: .normal),
        ]
        let view = RisoTaskDetailContentView(
            task: task,
            placements: [],
            affectedBoards: [],
            parentCompounds: [],
            compoundChildren: children,
            templates: [],
            onEditSubmit: { _ in },
            onDeleteTap: {},
            onOpenTask: { _ in },
            onOpenBoard: { _ in }
        )
        .frame(width: 393, height: 600)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 600), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - Private helpers

    private func controlsView(
        typeFilter: TasksTabTypeFilter,
        sortBy: TasksTabSort,
        resultCount: Int
    ) -> some View {
        // Use @State via a wrapper so SwiftUI doesn't complain about
        // non-@State bindings in snapshot context.
        ControlsWrapper(
            initialType: typeFilter,
            initialSort: sortBy,
            resultCount: resultCount
        )
        .padding(12)
        .background(Color.risoPaper)
        .frame(width: 353, height: 200)
    }
}

// MARK: - Stateful wrapper for controls snapshot

/// Thin SwiftUI view that owns the @State bindings needed by
/// `RisoTasksControlsView` so snapshot renders are valid.
private struct ControlsWrapper: View {
    @State private var search = ""
    @State private var typeFilter: TasksTabTypeFilter
    @State private var statusFilter: TasksTabStatusFilter = .any
    @State private var usageFilter: TasksTabUsageFilter = .any
    @State private var sortBy: TasksTabSort
    @State private var showExpired = false
    @State private var groupByCompound = true
    let resultCount: Int

    init(initialType: TasksTabTypeFilter, initialSort: TasksTabSort, resultCount: Int) {
        _typeFilter = State(initialValue: initialType)
        _sortBy = State(initialValue: initialSort)
        self.resultCount = resultCount
    }

    var body: some View {
        RisoTasksControlsView(
            search: $search,
            typeFilter: $typeFilter,
            statusFilter: $statusFilter,
            usageFilter: $usageFilter,
            sortBy: $sortBy,
            showExpired: $showExpired,
            groupByCompound: $groupByCompound,
            resultCount: resultCount
        )
    }
}

// MARK: - Stateful wrapper for Tasks-tab header + Pools segment snapshot

/// Thin SwiftUI view reproducing `TasksTabView.headerRow` + `.segmentRow`'s
/// composition (kicker + H1 + pill segment) with its own `@State` binding,
/// so the pairing renders in isolation without touching `TasksTabView`
/// itself (self-loading, excluded — see class doc). Uses the exact same
/// production modifiers/component as the real screen, just not the
/// private computed properties directly.
private struct TasksTabHeaderSegmentPreview: View {
    private enum Segment: Hashable { case library, pools }
    @State private var segment: Segment = .pools

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your library").risoKicker()
                    Text("Tasks").risoH1()
                }
                Spacer(minLength: 12)
                RisoIconButton(systemImage: "plus") {}
            }
            RisoSegmented(
                options: [(Segment.library, "Library"), (Segment.pools, "Pools · 2")],
                selection: $segment,
                style: .pill
            )
        }
    }
}
