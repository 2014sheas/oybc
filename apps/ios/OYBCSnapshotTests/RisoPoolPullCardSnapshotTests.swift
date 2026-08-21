import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `RisoPoolPullCardView` — the wizard Tasks step's
/// "PULL IN A POOL" card (Task Pools + Recurring Boards Rework, P3). Props-
/// only, DB-free leaf view, mirroring `RisoPoolsSnapshotTests`' pattern.
/// See docs/POOLS_RECURRING.md §Surfaces item 5 (Wizard step 2).
final class RisoPoolPullCardSnapshotTests: XCTestCase {

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

    private func card(pools: [Pool], pulledPoolIds: [String]) -> some View {
        ZStack {
            RisoPaperBackground()
            RisoPoolPullCardView(
                pools: pools,
                pulledPoolIds: pulledPoolIds,
                onToggle: { _ in }
            )
            .padding(Riso.gutter)
        }
    }

    // MARK: - Empty (no pools yet)

    func testEmptyLight() {
        assertSnapshot(
            of: card(pools: [], pulledPoolIds: []),
            as: .image(layout: .fixed(width: 393, height: 110), traits: lightTraits()),
            record: recordMode
        )
    }

    func testEmptyDark() {
        assertSnapshot(
            of: card(pools: [], pulledPoolIds: []),
            as: .image(layout: .fixed(width: 393, height: 110), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - Populated, none pulled

    private func populatedPools() -> [Pool] {
        [
            pool("p1", "Morning Kickstart", taskIds: ["t1", "t2", "t3"]),
            pool("p2", "Evening wind-down", taskIds: ["t4", "t5"]),
            pool("p3", "Weekly Reset", taskIds: ["t6"]),
        ]
    }

    func testPopulatedNonePulledLight() {
        assertSnapshot(
            of: card(pools: populatedPools(), pulledPoolIds: []),
            as: .image(layout: .fixed(width: 393, height: 120), traits: lightTraits()),
            record: recordMode
        )
    }

    func testPopulatedNonePulledDark() {
        assertSnapshot(
            of: card(pools: populatedPools(), pulledPoolIds: []),
            as: .image(layout: .fixed(width: 393, height: 120), traits: darkTraits()),
            record: recordMode
        )
    }

    // MARK: - Populated, one pulled (proves the ON/OFF chip states both render)

    func testPopulatedOnePulledLight() {
        assertSnapshot(
            of: card(pools: populatedPools(), pulledPoolIds: ["p1"]),
            as: .image(layout: .fixed(width: 393, height: 120), traits: lightTraits()),
            record: recordMode
        )
    }

    func testPopulatedOnePulledDark() {
        assertSnapshot(
            of: card(pools: populatedPools(), pulledPoolIds: ["p1"]),
            as: .image(layout: .fixed(width: 393, height: 120), traits: darkTraits()),
            record: recordMode
        )
    }
}
