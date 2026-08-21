import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for `BoardWizardTasksStepView` — Phase 3b Riso redesign.
///
/// Full-step variants (all re-recorded after the 3b restructure):
///   - empty library (pool header 0/25, quick-add, dashed buttons, empty-pool note)
///   - dense library, nothing selected
///   - dense library, several rows in the pool (pool list rows visible)
///   - center-task mode active (center-task indicator in pool header)
///   - recurring-template variant ("N extra shuffle in each spawn" copy)
///
/// Leaf-component variants (new in 3b for targeted regression checks):
///   - pool header: short / satisfied (light + dark)
///   - pool list: with tasks (light + dark)
///   - empty pool state (light + dark)
///
/// Each test renders at iPhone 16 width (393pt). iOS-version pinning is
/// enforced at the scheme level (see CLAUDE.md → Snapshot Testing).
final class BoardWizardTasksStepSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Full-step variants (re-recorded after 3b)

    func testEmptyLibrary() {
        let view = makeView(libraryState: .empty)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testDenseLibraryUnselected() {
        let view = makeView(libraryState: .dense)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testDenseLibrarySomeSelected() {
        let view = makeView(
            libraryState: .dense,
            initialSelection: ["t-normal-1", "t-counting-1", "t-compound-and"]
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testDenseLibraryCenterTaskMode() {
        let view = makeView(
            libraryState: .dense,
            initialSelection: ["t-normal-1", "t-counting-1"],
            centerTaskMode: true,
            initialCenterTaskId: "t-normal-1"
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testDenseLibraryRecurringSomeSelected() {
        let view = makeView(
            libraryState: .dense,
            initialSelection: ["t-normal-1", "t-counting-1", "t-compound-and"],
            isRecurring: true
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    // MARK: - Leaf: Pool header card

    func testPoolHeaderShortLight() {
        let view = RisoTasksPoolHeaderView(
            selectedCount: 3,
            tasksRequired: 25,
            isRecurring: false,
            centerTaskMode: false,
            centerSatisfied: false
        )
        .padding(20)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 130)),
            record: recordMode
        )
    }

    func testPoolHeaderSatisfiedLight() {
        let view = RisoTasksPoolHeaderView(
            selectedCount: 27,
            tasksRequired: 25,
            isRecurring: false,
            centerTaskMode: true,
            centerSatisfied: true
        )
        .padding(20)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 160)),
            record: recordMode
        )
    }

    func testPoolHeaderShortDark() {
        let view = RisoTasksPoolHeaderView(
            selectedCount: 3,
            tasksRequired: 25,
            isRecurring: false,
            centerTaskMode: false,
            centerSatisfied: false
        )
        .padding(20)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 130),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    func testPoolHeaderSatisfiedDark() {
        let view = RisoTasksPoolHeaderView(
            selectedCount: 27,
            tasksRequired: 25,
            isRecurring: true,
            centerTaskMode: false,
            centerSatisfied: false
        )
        .padding(20)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 130),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Leaf: Pool list (selected tasks)

    func testPoolListWithTasksLight() {
        let view = makePoolListView()
            .padding(20)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 300)),
            record: recordMode
        )
    }

    func testPoolListWithTasksDark() {
        let view = makePoolListView()
            .padding(20)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 300),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    func testPoolListEmptyLight() {
        let view = RisoPoolListView(
            selectedTaskIds: [],
            orderedTaskIds: [],
            effectiveTaskById: [:],
            effectiveChildrenByCompound: [:],
            isRecurring: false,
            onRemove: { _ in }
        )
        .padding(20)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 120)),
            record: recordMode
        )
    }

    func testPoolListEmptyDark() {
        let view = RisoPoolListView(
            selectedTaskIds: [],
            orderedTaskIds: [],
            effectiveTaskById: [:],
            effectiveChildrenByCompound: [:],
            isRecurring: false,
            onRemove: { _ in }
        )
        .padding(20)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 120),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Leaf: Pool list in center-task (CHOSEN) mode

    /// Bug fix: in CHOSEN center mode each pool row shows a tappable star,
    /// and the marked row is highlighted gold. Proves the center picker
    /// actually renders (it was previously absent — "Choose" was a dead end).
    func testPoolListCenterModeLight() {
        let view = makePoolListView(centerTaskMode: true, centerTaskId: "t-counting-1")
            .padding(20)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 300)),
            record: recordMode
        )
    }

    func testPoolListCenterModeDark() {
        let view = makePoolListView(centerTaskMode: true, centerTaskId: "t-counting-1")
            .padding(20)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 300),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Full-step: PULL IN A POOL card + provenance (P3)

    /// Proves the new "PULL IN A POOL" card renders with real pools, one
    /// pulled, and that pool-sourced + hand-added rows both get correct
    /// provenance subtitles in situ (not just at the leaf-view level below).
    func testDenseLibraryWithPoolsPulledAndProvenance() {
        let view = makeView(
            libraryState: .dense,
            initialSelection: ["t-normal-1", "t-counting-1", "t-compound-and"],
            pools: [
                SnapshotFixtures.makeTestPool(id: "p1", name: "Morning Kickstart", taskIds: ["t-normal-1", "t-counting-1"]),
                SnapshotFixtures.makeTestPool(id: "p2", name: "Evening wind-down", taskIds: ["t-compound-and"]),
            ],
            pulledPoolIds: ["p1"],
            provenanceByTaskId: [
                "t-normal-1": "from Morning Kickstart",
                "t-counting-1": "from Morning Kickstart",
                "t-compound-and": "added by hand",
            ]
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 900)),
            record: recordMode
        )
    }

    // MARK: - Builders

    private func makeView(
        libraryState: SnapshotFixtures.LibraryState,
        initialSelection: Set<String> = [],
        centerTaskMode: Bool = false,
        initialCenterTaskId: String? = nil,
        isRecurring: Bool = false,
        pools: [Pool] = [],
        pulledPoolIds: [String] = [],
        provenanceByTaskId: [String: String] = [:]
    ) -> some View {
        let library = SnapshotFixtures.makeTaskLibrary(state: libraryState)
        return TasksStepHost(
            library: library,
            initialSelection: initialSelection,
            initialCenterTaskId: initialCenterTaskId,
            centerTaskMode: centerTaskMode,
            isRecurring: isRecurring,
            pools: pools,
            pulledPoolIds: pulledPoolIds,
            provenanceByTaskId: provenanceByTaskId
        )
    }

    private func makePoolListView(
        centerTaskMode: Bool = false,
        centerTaskId: String? = nil,
        provenanceByTaskId: [String: String] = [:]
    ) -> some View {
        // Build a stable set of tasks for the pool list
        let normalTask = SnapshotFixtures.makeTask(id: "t-normal-1", title: "Meditate 10 min", type: .normal)
        let countingTask = SnapshotFixtures.makeTask(
            id: "t-counting-1",
            title: "Run 5 km",
            type: .counting,
            action: "Run",
            unit: "km",
            maxCount: 5
        )
        let compoundTask = SnapshotFixtures.makeTask(
            id: "t-compound-and",
            title: "Morning routine",
            type: .compound,
            operatorType: .and
        )
        let child1 = SnapshotFixtures.makeCompoundChild(
            id: "cc-1", compoundTaskId: "t-compound-and", childTaskId: "t-normal-1", childIndex: 0
        )
        let child2 = SnapshotFixtures.makeCompoundChild(
            id: "cc-2", compoundTaskId: "t-compound-and", childTaskId: "t-counting-1", childIndex: 1
        )

        let taskById: [String: OYBC.Task] = [
            normalTask.id: normalTask,
            countingTask.id: countingTask,
            compoundTask.id: compoundTask,
        ]
        let childrenByCompound: [String: [CompoundChild]] = [
            compoundTask.id: [child1, child2],
        ]
        let selectedIds: Set<String> = [normalTask.id, countingTask.id, compoundTask.id]

        return RisoPoolListView(
            selectedTaskIds: selectedIds,
            // Reproduce the previous alphabetical-by-title order so the baseline
            // is unchanged (rendering is now order-driven, not sorted).
            orderedTaskIds: [normalTask, countingTask, compoundTask]
                .sorted { $0.title < $1.title }.map(\.id),
            effectiveTaskById: taskById,
            effectiveChildrenByCompound: childrenByCompound,
            isRecurring: false,
            onRemove: { _ in },
            centerTaskMode: centerTaskMode,
            centerTaskId: centerTaskId,
            onSetCenter: { _ in },
            onEdit: { _ in },
            provenanceByTaskId: provenanceByTaskId
        )
    }

    // MARK: - Leaf: Pool list provenance subtitles (P3)

    func testPoolListWithProvenanceLight() {
        let view = makePoolListView(provenanceByTaskId: [
            "t-normal-1": "from Morning Kickstart",
            "t-counting-1": "from Morning Kickstart",
            "t-compound-and": "added by hand",
        ])
        .padding(20)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 300)),
            record: recordMode
        )
    }

    func testPoolListWithProvenanceDark() {
        let view = makePoolListView(provenanceByTaskId: [
            "t-normal-1": "from Morning Kickstart",
            "t-counting-1": "from Morning Kickstart",
            "t-compound-and": "added by hand",
        ])
        .padding(20)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 300),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }
}

/// Wraps `BoardWizardTasksStepView` in a parent that owns the @State
/// values it binds to. Snapshot tests render this host so the bindings
/// resolve without going through `BoardWizardView`.
private struct TasksStepHost: View {
    let library: TaskLibraryViewModel
    @State var selectedTaskIds: Set<String>
    @State var centerTaskId: String?
    let centerTaskMode: Bool
    let isRecurring: Bool
    // Task Pools + Recurring Boards Rework (P3) — pull-card fixtures.
    let pools: [Pool]
    let pulledPoolIds: [String]
    let provenanceByTaskId: [String: String]

    init(
        library: TaskLibraryViewModel,
        initialSelection: Set<String>,
        initialCenterTaskId: String?,
        centerTaskMode: Bool,
        isRecurring: Bool,
        pools: [Pool] = [],
        pulledPoolIds: [String] = [],
        provenanceByTaskId: [String: String] = [:]
    ) {
        self.library = library
        self._selectedTaskIds = State(initialValue: initialSelection)
        self._centerTaskId = State(initialValue: initialCenterTaskId)
        self.centerTaskMode = centerTaskMode
        self.isRecurring = isRecurring
        self.pools = pools
        self.pulledPoolIds = pulledPoolIds
        self.provenanceByTaskId = provenanceByTaskId
    }

    /// Reproduce the previous alphabetical-by-title pool order so baselines are
    /// unchanged now that the list renders by `poolOrder` instead of sorting.
    private var poolOrder: [String] {
        let byId = Dictionary(
            library.libraryTasks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return selectedTaskIds.sorted { (byId[$0]?.title ?? $0) < (byId[$1]?.title ?? $1) }
    }

    var body: some View {
        BoardWizardTasksStepView(
            library: library,
            selectedTaskIds: $selectedTaskIds,
            poolOrder: poolOrder,
            tasksRequired: 25,
            isRecurring: isRecurring,
            centerTaskMode: centerTaskMode,
            centerTaskId: $centerTaskId,
            userId: SnapshotFixtures.userId,
            // .custom hides the "From parent boards" filter chip (no parent
            // timeframes for custom), keeping baselines stable.
            currentTimeframe: .custom,
            onToggleSelection: { _ in },
            onTaskCreated: { _, _, _ in },
            onCompoundCreated: { _ in },
            onLibraryReloadRequested: { },
            onBack: { },
            onNext: { },
            pools: pools,
            pulledPoolIds: pulledPoolIds,
            provenanceByTaskId: provenanceByTaskId
        )
    }
}
