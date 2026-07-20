import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Task Pools + Recurring Boards Rework (P2)
/// Tasks-tab Pools segment surfaces: `PoolsBrowseView` (browse list +
/// dashed "+ New pool") and `PoolEditSheetView` (create/edit sheet). Both
/// are DB-free, props-only leaf views (mirrors `RisoTasksTabSnapshotTests`'
/// pattern) — fixture data only, no `AppDatabase.shared` involved. See
/// docs/POOLS_RECURRING.md §Surfaces items 1-2 + the handoff screenshots
/// `01-pools.png` / `02-pool-edit-sheet.png`.
final class RisoPoolsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private let ts = SnapshotFixtures.fixedTimestamp

    private func lightTraits() -> UITraitCollection { UITraitCollection(userInterfaceStyle: .light) }
    private func darkTraits() -> UITraitCollection { UITraitCollection(userInterfaceStyle: .dark) }

    private func pool(_ id: String, _ name: String, taskIds: [String]) -> Pool {
        Pool(
            id: id, userId: SnapshotFixtures.userId, name: name, taskIds: taskIds,
            createdAt: ts, updatedAt: ts, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    // MARK: - PoolsBrowseView

    private func browseView(
        pools: [Pool],
        tasksById: [String: [Task]],
        healthById: [String: PoolHealth.Result]
    ) -> some View {
        ZStack {
            RisoPaperBackground()
            PoolsBrowseView(
                pools: pools,
                poolTasksById: tasksById,
                healthByPoolId: healthById,
                onSelectPool: { _ in },
                onNewPool: {}
            )
            .padding(Riso.gutter)
        }
    }

    // MARK: - PoolsBrowseView — populated

    private func populatedFixtures() -> ([Pool], [String: [Task]], [String: PoolHealth.Result]) {
        let morningTasks = [
            SnapshotFixtures.makeTask(id: "t1", title: "Meditate 10 min", type: .normal),
            SnapshotFixtures.makeTask(id: "t2", title: "Drink 64 oz water", type: .normal),
            SnapshotFixtures.makeTask(id: "t3", title: "Read 30 min", type: .normal),
            SnapshotFixtures.makeTask(id: "t4", title: "Walk the dog", type: .normal),
            SnapshotFixtures.makeTask(id: "t5", title: "Stretch 5 min", type: .normal),
        ]
        let eveningTasks = [
            SnapshotFixtures.makeTask(id: "t6", title: "Journal", type: .normal),
            SnapshotFixtures.makeTask(id: "t7", title: "Read before bed", type: .normal),
        ]
        let morning = pool("p1", "Morning Kickstart", taskIds: morningTasks.map { $0.id })
        let evening = pool("p2", "Evening wind-down", taskIds: eveningTasks.map { $0.id })
        return (
            [morning, evening],
            [morning.id: morningTasks, evening.id: eveningTasks],
            [
                morning.id: PoolHealth.Result(taskCount: morningTasks.count, consumers: []),
                evening.id: PoolHealth.Result(taskCount: eveningTasks.count, consumers: []),
            ]
        )
    }

    func testBrowsePopulatedLight() {
        let (pools, tasksById, healthById) = populatedFixtures()
        assertSnapshot(
            of: browseView(pools: pools, tasksById: tasksById, healthById: healthById),
            as: .image(layout: .fixed(width: 393, height: 480), traits: lightTraits()),
            record: recordMode
        )
    }

    func testBrowsePopulatedDark() {
        let (pools, tasksById, healthById) = populatedFixtures()
        assertSnapshot(
            of: browseView(pools: pools, tasksById: tasksById, healthById: healthById),
            as: .image(layout: .fixed(width: 393, height: 480), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - PoolsBrowseView — empty

    func testBrowseEmptyLight() {
        assertSnapshot(
            of: browseView(pools: [], tasksById: [:], healthById: [:]),
            as: .image(layout: .fixed(width: 393, height: 180), traits: lightTraits()),
            record: recordMode
        )
    }

    func testBrowseEmptyDark() {
        assertSnapshot(
            of: browseView(pools: [], tasksById: [:], healthById: [:]),
            as: .image(layout: .fixed(width: 393, height: 180), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - PoolsBrowseView — short-warning

    private func shortWarningFixtures() -> ([Pool], [String: [Task]], [String: PoolHealth.Result]) {
        let tasks = [
            SnapshotFixtures.makeTask(id: "t1", title: "Water the plants", type: .normal),
            SnapshotFixtures.makeTask(id: "t2", title: "Call a friend", type: .normal),
        ]
        let weekly = pool("p1", "Weekly Reset", taskIds: tasks.map { $0.id })
        let health: [String: PoolHealth.Result] = [
            weekly.id: PoolHealth.Result(taskCount: tasks.count, consumers: [
                PoolHealth.Consumer(
                    templateId: "tpl1", templateName: "Weekly Reset",
                    timeframe: .weekly, boardSize: 3, shortBy: 6
                ),
            ]),
        ]
        return ([weekly], [weekly.id: tasks], health)
    }

    func testBrowseShortWarningLight() {
        let (pools, tasksById, healthById) = shortWarningFixtures()
        assertSnapshot(
            of: browseView(pools: pools, tasksById: tasksById, healthById: healthById),
            as: .image(layout: .fixed(width: 393, height: 320), traits: lightTraits()),
            record: recordMode
        )
    }

    func testBrowseShortWarningDark() {
        let (pools, tasksById, healthById) = shortWarningFixtures()
        assertSnapshot(
            of: browseView(pools: pools, tasksById: tasksById, healthById: healthById),
            as: .image(layout: .fixed(width: 393, height: 320), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - PoolEditSheetView

    private func editSheet(existing: Bool) -> some View {
        let library = TaskLibraryViewModel()
        let tasks = [
            SnapshotFixtures.makeTask(id: "t1", title: "Meditate 10 min", type: .normal),
            SnapshotFixtures.makeTask(id: "t2", title: "Drink 64 oz water", type: .normal),
            SnapshotFixtures.makeTask(id: "t3", title: "Read 30 min", type: .normal),
        ]
        library.libraryTasks = tasks
        // None of the fixture tasks are wizard-born drafts, so the
        // browsable (picker) set is identical to the full library set —
        // keep both populated so a future test that opens the library
        // picker doesn't silently render empty (P2 I-2: the picker reads
        // `browsableTasks`, never `libraryTasks`).
        library.browsableTasks = tasks
        let existingPool = existing ? pool("p1", "Morning Kickstart", taskIds: ["t1", "t2"]) : nil
        return PoolEditSheetView(
            pool: existingPool,
            templates: [],
            library: library,
            userId: SnapshotFixtures.userId,
            onSaved: {},
            onDeleted: {}
        )
    }

    func testEditSheetNewLight() {
        assertSnapshot(
            of: editSheet(existing: false),
            as: .image(layout: .fixed(width: 393, height: 680), traits: lightTraits()),
            record: recordMode
        )
    }

    func testEditSheetNewDark() {
        assertSnapshot(
            of: editSheet(existing: false),
            as: .image(layout: .fixed(width: 393, height: 680), traits: darkTraits()),
            record: recordMode
        )
    }

    func testEditSheetEditLight() {
        assertSnapshot(
            of: editSheet(existing: true),
            as: .image(layout: .fixed(width: 393, height: 740), traits: lightTraits()),
            record: recordMode
        )
    }

    func testEditSheetEditDark() {
        assertSnapshot(
            of: editSheet(existing: true),
            as: .image(layout: .fixed(width: 393, height: 740), traits: darkTraits()),
            record: recordMode
        )
    }
}
