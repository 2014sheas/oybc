import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Task Pools + Recurring Boards Rework (P7)
/// Board-settings surfaces: `CoreDefaultsEditSheetView` and the shared
/// `PoolPickerSheetView`. Both are DB-free, props-only leaf views during
/// RENDER (writes only happen inside action closures, never on appear) —
/// the exact pattern `PoolEditSheetView` already proved snapshot-safe in
/// `RisoPoolsSnapshotTests`. `BoardSettingsView` itself is NOT snapshotted
/// here — see `RisoProfileSubpagesSnapshotTests`'s file header for why.
///
/// Board Creation Split (PR B) retired the local `RepeatingBoardEditSheetView`
/// this file used to also cover (`testRosterEdit*`) — editing a repeating
/// board's roster entry now opens the full `BoardWizardView` in edit mode
/// instead, which is exercised by the wizard's own snapshot coverage, not
/// re-snapshotted per entry point here.
final class BoardSettingsSnapshotTests: XCTestCase {

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

    private func makeLibrary(_ tasks: [Task]) -> TaskLibraryViewModel {
        let library = TaskLibraryViewModel()
        library.libraryTasks = tasks
        library.browsableTasks = tasks
        return library
    }

    // MARK: - Shared fixture data

    private let t1 = SnapshotFixtures.makeTask(id: "t1", title: "Meditate 10 min", type: .normal)
    private let t2 = SnapshotFixtures.makeTask(id: "t2", title: "Drink 64 oz water", type: .normal)
    private let t3 = SnapshotFixtures.makeTask(id: "t3", title: "Read 30 min", type: .normal)
    private let t4 = SnapshotFixtures.makeTask(id: "t4", title: "Stretch 5 min", type: .normal)

    // MARK: - CoreDefaultsEditSheetView

    private func defaultsSheet(hasDefault: Bool) -> some View {
        let pools = [pool("p1", "Morning Kickstart", taskIds: [t1.id, t2.id])]
        let coreDefault = hasDefault
            ? SnapshotFixtures.makeCoreBoardDefault(
                id: "cd1", timeframe: .daily, corePoolIds: ["p1"], coreDefaultTaskIds: [t4.id]
              )
            : nil
        return CoreDefaultsEditSheetView(
            timeframe: .daily,
            coreDefault: coreDefault,
            pools: pools,
            tasks: [t1, t2, t3, t4],
            templates: [],
            library: makeLibrary([t1, t2, t3, t4]),
            userId: SnapshotFixtures.userId,
            onSaved: {}
        )
    }

    func testDefaultsEmptyLight() {
        assertSnapshot(of: defaultsSheet(hasDefault: false), as: .image(layout: .fixed(width: 393, height: 560), traits: lightTraits()), record: recordMode)
    }
    func testDefaultsEmptyDark() {
        assertSnapshot(of: defaultsSheet(hasDefault: false), as: .image(layout: .fixed(width: 393, height: 560), traits: darkTraits()), record: recordMode)
    }
    func testDefaultsPopulatedLight() {
        assertSnapshot(of: defaultsSheet(hasDefault: true), as: .image(layout: .fixed(width: 393, height: 620), traits: lightTraits()), record: recordMode)
    }
    func testDefaultsPopulatedDark() {
        assertSnapshot(of: defaultsSheet(hasDefault: true), as: .image(layout: .fixed(width: 393, height: 620), traits: darkTraits()), record: recordMode)
    }

    // MARK: - PoolPickerSheetView

    private func poolPicker() -> some View {
        let morning = pool("p1", "Morning Kickstart", taskIds: [t1.id, t2.id])
        let evening = pool("p2", "Evening Wind-down", taskIds: [t3.id])
        let template = SnapshotFixtures.makeRecurringTemplate(
            id: "tpl1", name: "Evening Wind-down", timeframe: .daily, boardSize: 5,
            centerSquareType: .free, seedTaskCount: 0, isActive: true,
            poolIds: ["p2"], manualTaskIds: [], removedTaskIds: []
        )
        let health: [String: PoolHealth.Result] = [
            morning.id: PoolHealth.Result(taskCount: 2, consumers: []),
            evening.id: PoolHealth.Result(taskCount: 1, consumers: [
                PoolHealth.Consumer(templateId: "tpl1", templateName: "Evening Wind-down", timeframe: .daily, boardSize: 5, shortBy: 15),
            ]),
        ]
        return PoolPickerSheetView(
            pools: [morning, evening],
            selectedPoolIds: [morning.id],
            healthByPoolId: health,
            templates: [template],
            library: makeLibrary([t1, t2, t3]),
            userId: SnapshotFixtures.userId,
            onToggle: { _ in },
            onPoolCreated: { _ in }
        )
    }

    func testPoolPickerLight() {
        assertSnapshot(of: poolPicker(), as: .image(layout: .fixed(width: 393, height: 420), traits: lightTraits()), record: recordMode)
    }
    func testPoolPickerDark() {
        assertSnapshot(of: poolPicker(), as: .image(layout: .fixed(width: 393, height: 420), traits: darkTraits()), record: recordMode)
    }
}
