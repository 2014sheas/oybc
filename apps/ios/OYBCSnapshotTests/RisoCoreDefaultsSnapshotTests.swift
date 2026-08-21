import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Task Pools + Recurring Boards Rework (P5) — core-board setup surfaces:
/// the provenance chip strip, the red fillable-floor gate, and the "Start
/// every <TF> board with 'X'" checkbox (docs/POOLS_RECURRING.md §Surfaces
/// item 6). Follows `RisoPoolPullCardSnapshotTests`'s light/dark +
/// fixed-width leaf-component convention.
final class RisoCoreDefaultsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func lightTraits() -> UITraitCollection { UITraitCollection(userInterfaceStyle: .light) }
    private func darkTraits() -> UITraitCollection { UITraitCollection(userInterfaceStyle: .dark) }

    // MARK: - RisoCoreDefaultChipStripView

    private func chipStrip(orderedTaskIds: [String], manualTaskIds: Set<String>, taskById: [String: OYBC.Task]) -> some View {
        ZStack {
            RisoPaperBackground()
            RisoCoreDefaultChipStripView(
                orderedTaskIds: orderedTaskIds,
                manualTaskIds: manualTaskIds,
                taskById: taskById,
                onRemove: { _ in }
            )
            .padding(Riso.gutter)
        }
    }

    func testChipStrip_EmptyLight() {
        assertSnapshot(
            of: chipStrip(orderedTaskIds: [], manualTaskIds: [], taskById: [:]),
            as: .image(layout: .fixed(width: 393, height: 70), traits: lightTraits()),
            record: recordMode
        )
    }

    func testChipStrip_EmptyDark() {
        assertSnapshot(
            of: chipStrip(orderedTaskIds: [], manualTaskIds: [], taskById: [:]),
            as: .image(layout: .fixed(width: 393, height: 70), traits: darkTraits()),
            record: recordMode
        )
    }

    private func plainOnlyFixture() -> (ids: [String], manual: Set<String>, byId: [String: OYBC.Task]) {
        let t1 = SnapshotFixtures.makeTask(id: "t1", title: "Drink water", type: .normal)
        let t2 = SnapshotFixtures.makeTask(id: "t2", title: "Stretch", type: .normal)
        return (["t1", "t2"], [], ["t1": t1, "t2": t2])
    }

    func testChipStrip_PlainOnlyLight() {
        let f = plainOnlyFixture()
        assertSnapshot(
            of: chipStrip(orderedTaskIds: f.ids, manualTaskIds: f.manual, taskById: f.byId),
            as: .image(layout: .fixed(width: 393, height: 70), traits: lightTraits()),
            record: recordMode
        )
    }

    func testChipStrip_PlainOnlyDark() {
        let f = plainOnlyFixture()
        assertSnapshot(
            of: chipStrip(orderedTaskIds: f.ids, manualTaskIds: f.manual, taskById: f.byId),
            as: .image(layout: .fixed(width: 393, height: 70), traits: darkTraits()),
            record: recordMode
        )
    }

    /// Proves BOTH chip variants render side by side: "Drink water" /
    /// "Stretch" are pre-filled (plain), "Walk the dog" is hand-added
    /// (blue-tinted with ✕).
    private func mixedFixture() -> (ids: [String], manual: Set<String>, byId: [String: OYBC.Task]) {
        let t1 = SnapshotFixtures.makeTask(id: "t1", title: "Drink water", type: .normal)
        let t2 = SnapshotFixtures.makeTask(id: "t2", title: "Stretch", type: .normal)
        let t3 = SnapshotFixtures.makeTask(id: "t3", title: "Walk the dog", type: .normal)
        return (["t1", "t2", "t3"], ["t3"], ["t1": t1, "t2": t2, "t3": t3])
    }

    func testChipStrip_PlainAndManualMixedLight() {
        let f = mixedFixture()
        assertSnapshot(
            of: chipStrip(orderedTaskIds: f.ids, manualTaskIds: f.manual, taskById: f.byId),
            as: .image(layout: .fixed(width: 393, height: 70), traits: lightTraits()),
            record: recordMode
        )
    }

    func testChipStrip_PlainAndManualMixedDark() {
        let f = mixedFixture()
        assertSnapshot(
            of: chipStrip(orderedTaskIds: f.ids, manualTaskIds: f.manual, taskById: f.byId),
            as: .image(layout: .fixed(width: 393, height: 70), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - RisoCoreFloorGateView (red floor-gate state)

    private func floorGate(remaining: Int) -> some View {
        ZStack {
            RisoPaperBackground()
            RisoCoreFloorGateView(remaining: remaining)
                .padding(Riso.gutter)
        }
    }

    func testFloorGate_Light() {
        assertSnapshot(
            of: floorGate(remaining: 3),
            as: .image(layout: .fixed(width: 393, height: 50), traits: lightTraits()),
            record: recordMode
        )
    }

    func testFloorGate_Dark() {
        assertSnapshot(
            of: floorGate(remaining: 3),
            as: .image(layout: .fixed(width: 393, height: 50), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - RisoCheckboxRow (visible / checked / unchecked)

    private func checkbox(isOn: Bool, label: String = "Start every Weekly board with \"Morning Kickstart\"") -> some View {
        ZStack {
            RisoPaperBackground()
            RisoCheckboxRow(label: label, isOn: isOn, action: {})
                .padding(Riso.gutter)
        }
    }

    func testCheckbox_UncheckedLight() {
        assertSnapshot(
            of: checkbox(isOn: false),
            as: .image(layout: .fixed(width: 393, height: 60), traits: lightTraits()),
            record: recordMode
        )
    }

    func testCheckbox_UncheckedDark() {
        assertSnapshot(
            of: checkbox(isOn: false),
            as: .image(layout: .fixed(width: 393, height: 60), traits: darkTraits()),
            record: recordMode
        )
    }

    func testCheckbox_CheckedLight() {
        assertSnapshot(
            of: checkbox(isOn: true),
            as: .image(layout: .fixed(width: 393, height: 60), traits: lightTraits()),
            record: recordMode
        )
    }

    func testCheckbox_CheckedDark() {
        assertSnapshot(
            of: checkbox(isOn: true),
            as: .image(layout: .fixed(width: 393, height: 60), traits: darkTraits()),
            record: recordMode
        )
    }

    func testCheckbox_MultiPoolLabelLight() {
        assertSnapshot(
            of: checkbox(isOn: true, label: "Start every Weekly board with these pools"),
            as: .image(layout: .fixed(width: 393, height: 60), traits: lightTraits()),
            record: recordMode
        )
    }
}
