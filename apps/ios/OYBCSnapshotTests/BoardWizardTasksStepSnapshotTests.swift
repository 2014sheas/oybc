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
///   - pool list: a hand-added counting row with the dice on (light + dark)
///
/// Board Sources §Member rules (B3) full-step variants — an expanded
/// board source over the `.memberRules` library:
///   - counting member: target stepper + "of 35 mi" caption + dice off
///   - counting member with the dice on: the blue range line
///   - the same counting member pulled from a POOL: dice, no stepper
///   - compound member One square: pill toggle + "1 square" + line dice
///   - compound member Split up with an excluded part
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
            capacity: 3,
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
            capacity: 27,
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
            capacity: 3,
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
            capacity: 27,
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

    // MARK: - Full-step: source rows (Board Sources P2)

    /// The sources model in situ: one pulled pool source (collapsed) and
    /// one pulled board source EXPANDED (segmented filter + range block +
    /// member rows with an exclusion), above a hand-added task row.
    func testDenseLibraryWithSourcesPulled() {
        let poolSource = BoardSource(sourceId: "p1", kind: .pool)
        var boardSource = BoardSource(sourceId: "b1", kind: .board)
        boardSource.min = 1
        boardSource.max = 2
        boardSource.excludedTaskIds = ["t-counting-1"]
        let view = makeView(
            libraryState: .dense,
            initialSelection: ["t-compound-and"],
            pools: [
                SnapshotFixtures.makeTestPool(id: "p1", name: "Morning Kickstart", taskIds: ["t-normal-1", "t-counting-1"]),
            ],
            sources: [poolSource, boardSource],
            supplyInfoBySourceId: [
                "p1": WizardSourceSupply(
                    displayName: "Morning Kickstart",
                    rawSupplyTaskIds: ["t-normal-1", "t-counting-1"],
                    doneTaskIds: []
                ),
                "b1": WizardSourceSupply(
                    displayName: "Weekday Core",
                    rawSupplyTaskIds: ["t-normal-2", "t-counting-1", "t-normal-1"],
                    doneTaskIds: ["t-normal-2"]
                ),
            ],
            expandedSourceIds: ["b1"]
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 1200)),
            record: recordMode
        )
    }

    // MARK: - Full-step: member rules (B3)

    /// A board source pulled onto a one-off board: its counting member
    /// carries the 22pt target stepper + "of 35 mi" caption + dice (off),
    /// while the plain member carries only the ✕.
    func testSourceCountingMemberRule() {
        assertSnapshot(
            of: makeMemberRulesView(rules: [:]),
            as: .image(layout: .fixed(width: 393, height: 900)),
            record: recordMode
        )
    }

    /// Same source with the dice turned up: the blue range line appears
    /// under the row at the 69pt indent.
    func testSourceCountingMemberVaryOn() {
        assertSnapshot(
            of: makeMemberRulesView(
                rules: [SnapshotFixtures.MemberRuleTask.run: BoardSourceMemberRule(vary: .little)]
            ),
            as: .image(layout: .fixed(width: 393, height: 900)),
            record: recordMode
        )
    }

    /// RC5's headline distinction: the SAME counting member pulled from a
    /// POOL has no window to pro-rate against, so it gets the dice ALONE
    /// — no stepper, no "of 35 mi" caption (and the panel has no
    /// All squares / Not done yet filter, which is boards-only).
    func testPoolSourceCountingMemberHasDiceButNoStepper() {
        assertSnapshot(
            of: makeMemberRulesView(
                kind: .pool,
                rules: [SnapshotFixtures.MemberRuleTask.run: BoardSourceMemberRule(vary: .little)]
            ),
            as: .image(layout: .fixed(width: 393, height: 900)),
            record: recordMode
        )
    }

    /// Compound member in One square mode: the pill toggle + "1 square"
    /// note + the dice on THAT line (rolling for the whole square), with
    /// each part line reading the parent's level for its range.
    func testSourceCompoundOneSquare() {
        assertSnapshot(
            of: makeMemberRulesView(
                memberIds: [
                    SnapshotFixtures.MemberRuleTask.compound,
                    SnapshotFixtures.MemberRuleTask.normal,
                ],
                rules: [
                    SnapshotFixtures.MemberRuleTask.compound: BoardSourceMemberRule(vary: .lot),
                ]
            ),
            as: .image(layout: .fixed(width: 393, height: 900)),
            record: recordMode
        )
    }

    /// Compound member Split up with one of its two parts excluded: the
    /// note drops to "1 square", the excluded part is struck with an
    /// UNDO pill, and the LAST included part shows no ✕.
    func testSourceCompoundSplitUpWithExcludedPart() {
        assertSnapshot(
            of: makeMemberRulesView(
                memberIds: [
                    SnapshotFixtures.MemberRuleTask.compound,
                    SnapshotFixtures.MemberRuleTask.normal,
                ],
                rules: [
                    SnapshotFixtures.MemberRuleTask.compound: BoardSourceMemberRule(
                        split: true,
                        parts: [
                            SnapshotFixtures.MemberRuleTask.plank:
                                BoardSourcePartRule(excluded: true),
                        ]
                    ),
                ]
            ),
            as: .image(layout: .fixed(width: 393, height: 900)),
            record: recordMode
        )
    }

    // MARK: - Leaf: hand-added rows with the dice (B3)

    /// A hand-added COUNTING row earns a dice before the 32pt pencil, and
    /// a blue range line under the row left-aligned with the title. The
    /// normal + compound rows in the same list get neither.
    func testPoolListHandAddedVaryLight() {
        let view = makePoolListView(manualTaskVary: ["t-counting-1": .lot])
            .padding(20)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 300)),
            record: recordMode
        )
    }

    func testPoolListHandAddedVaryDark() {
        let view = makePoolListView(manualTaskVary: ["t-counting-1": .lot])
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

    // MARK: - Builders

    private func makeView(
        libraryState: SnapshotFixtures.LibraryState,
        initialSelection: Set<String> = [],
        centerTaskMode: Bool = false,
        initialCenterTaskId: String? = nil,
        isRecurring: Bool = false,
        pools: [Pool] = [],
        sources: [BoardSource] = [],
        supplyInfoBySourceId: [String: WizardSourceSupply] = [:],
        expandedSourceIds: Set<String> = []
    ) -> some View {
        let library = SnapshotFixtures.makeTaskLibrary(state: libraryState)
        return TasksStepHost(
            library: library,
            initialSelection: initialSelection,
            initialCenterTaskId: initialCenterTaskId,
            centerTaskMode: centerTaskMode,
            isRecurring: isRecurring,
            pools: pools,
            sources: sources,
            supplyInfoBySourceId: supplyInfoBySourceId,
            expandedSourceIds: expandedSourceIds
        )
    }

    /// One expanded BOARD source over the `.memberRules` library, with
    /// `memberRules` stamped straight onto the `BoardSource` (that IS
    /// where rules live — no extra plumbing).
    private func makeMemberRulesView(
        kind: BoardSource.Kind = .board,
        memberIds: [String] = [
            SnapshotFixtures.MemberRuleTask.run,
            SnapshotFixtures.MemberRuleTask.normal,
        ],
        rules: [String: BoardSourceMemberRule]
    ) -> some View {
        let sourceId = kind == .pool ? "p1" : "b1"
        var source = BoardSource(sourceId: sourceId, kind: kind)
        source.memberRules = rules.isEmpty ? nil : rules
        return TasksStepHost(
            library: SnapshotFixtures.makeTaskLibrary(state: .memberRules),
            initialSelection: [],
            initialCenterTaskId: nil,
            centerTaskMode: false,
            isRecurring: false,
            sources: [source],
            supplyInfoBySourceId: [
                sourceId: WizardSourceSupply(
                    displayName: kind == .pool ? "Morning Kickstart" : "Weekday Core",
                    rawSupplyTaskIds: memberIds,
                    doneTaskIds: []
                ),
            ],
            expandedSourceIds: [sourceId]
        )
    }

    private func makePoolListView(
        centerTaskMode: Bool = false,
        centerTaskId: String? = nil,
        manualTaskVary: [String: VaryLevel] = [:]
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
            manualTaskVary: manualTaskVary,
            // Non-nil only here: wiring it on every existing fixture would
            // put a dice on baselines that never asked for one.
            onSetManualVary: manualTaskVary.isEmpty ? nil : { _, _ in }
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
    // Board Sources P2 — source-row fixtures.
    let pools: [Pool]
    let sources: [BoardSource]
    let supplyInfoBySourceId: [String: WizardSourceSupply]
    let expandedSourceIds: Set<String>
    let capacityOverride: Int?

    init(
        library: TaskLibraryViewModel,
        initialSelection: Set<String>,
        initialCenterTaskId: String?,
        centerTaskMode: Bool,
        isRecurring: Bool,
        pools: [Pool] = [],
        sources: [BoardSource] = [],
        supplyInfoBySourceId: [String: WizardSourceSupply] = [:],
        expandedSourceIds: Set<String> = [],
        capacityOverride: Int? = nil
    ) {
        self.library = library
        self._selectedTaskIds = State(initialValue: initialSelection)
        self._centerTaskId = State(initialValue: initialCenterTaskId)
        self.centerTaskMode = centerTaskMode
        self.isRecurring = isRecurring
        self.pools = pools
        self.sources = sources
        self.supplyInfoBySourceId = supplyInfoBySourceId
        self.expandedSourceIds = expandedSourceIds
        self.capacityOverride = capacityOverride
    }

    /// VM-less capacity mirror: dedupe(supplies ∪ selection-as-manual)
    /// — enough for stable snapshot fixtures. §Member rules (B3): the
    /// supplies run through the real `applyMemberRules`, so a Split-up
    /// member contributes its parts here exactly as it does on the board
    /// (a rule-less source is an identity pass, leaving pre-B3 baselines
    /// at the same number).
    private var capacity: Int {
        if let capacityOverride { return capacityOverride }
        let tasksById = Dictionary(
            library.libraryTasks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let raw = sources.map { source -> BoardSources.Supply in
            let info = supplyInfoBySourceId[source.sourceId]
            var ids = info?.rawSupplyTaskIds ?? []
            if source.kind == .board, source.filter == .todo, let done = info?.doneTaskIds {
                ids.removeAll { done.contains($0) }
            }
            ids.removeAll { source.excludedTaskIds.contains($0) }
            return BoardSources.Supply(source: source, supplyTaskIds: ids)
        }
        let expanded = BoardSources.applyMemberRules(
            raw,
            childrenByCompoundId: library.compoundChildrenByCompound,
            tasksById: tasksById
        )
        var unique = selectedTaskIds
        for supply in expanded { unique.formUnion(supply.supplyTaskIds) }
        return unique.count
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
            // Always "applied" — the snapshot host has no VM to refuse a
            // deselect (final review I1).
            onToggleSelection: { _ in true },
            onTaskCreated: { _, _, _ in },
            onCompoundCreated: { _ in },
            onLibraryReloadRequested: { },
            onBack: { },
            onNext: { },
            pools: pools,
            sources: sources,
            supplyInfoBySourceId: supplyInfoBySourceId,
            expandedSourceIds: expandedSourceIds,
            availableCountForSource: { sourceId in
                guard let source = sources.first(where: { $0.sourceId == sourceId }),
                      let info = supplyInfoBySourceId[sourceId] else { return 0 }
                return info.rawSupplyTaskIds.filter { !source.excludedTaskIds.contains($0) }.count
            },
            capacity: capacity
        )
    }
}
