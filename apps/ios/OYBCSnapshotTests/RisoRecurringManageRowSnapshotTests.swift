import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the P6 Board-screen recurring-management leaf
/// views (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
/// §Surfaces item 7): `RisoRecurringManageRow` (repeating board — active +
/// paused) and `RisoRepeatBoardCTA` (one-off board — collapsed + expanded
/// cadence picker).
///
/// Both are DB-free leaf views (no `AppDatabase.shared`, no
/// `@EnvironmentObject`), so — per CLAUDE.md's iOS snapshot guidance — they
/// can be snapshotted directly rather than through `BoardPlayView` (which
/// queries the production database singleton and isn't itself covered).
final class RisoRecurringManageRowSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private let lightTraits = UITraitCollection(userInterfaceStyle: .light)
    private let darkTraits  = UITraitCollection(userInterfaceStyle: .dark)

    // MARK: - RisoRecurringManageRow — active

    private func activeManageRow() -> some View {
        RisoRecurringManageRow(
            cadenceAdverb: "daily",
            templateName: "Morning Kickstart",
            isActive: true,
            onToggleActive: {}
        )
        .padding(Riso.gutter)
        .background(Color.risoPaper)
    }

    func testManageRowActiveLight() {
        assertSnapshot(of: activeManageRow(), as: .image(layout: .fixed(width: 393, height: 90), traits: lightTraits), record: recordMode)
    }

    func testManageRowActiveDark() {
        assertSnapshot(of: activeManageRow(), as: .image(layout: .fixed(width: 393, height: 90), traits: darkTraits), record: recordMode)
    }

    // MARK: - RisoRecurringManageRow — paused

    private func pausedManageRow() -> some View {
        RisoRecurringManageRow(
            cadenceAdverb: "weekly",
            templateName: "Morning Kickstart",
            isActive: false,
            onToggleActive: {}
        )
        .padding(Riso.gutter)
        .background(Color.risoPaper)
    }

    func testManageRowPausedLight() {
        assertSnapshot(of: pausedManageRow(), as: .image(layout: .fixed(width: 393, height: 90), traits: lightTraits), record: recordMode)
    }

    func testManageRowPausedDark() {
        assertSnapshot(of: pausedManageRow(), as: .image(layout: .fixed(width: 393, height: 90), traits: darkTraits), record: recordMode)
    }

    // MARK: - RisoRepeatBoardCTA — collapsed

    private func collapsedRepeatCTA() -> some View {
        RisoRepeatBoardCTA(onConfirm: { _ in })
            .padding(Riso.gutter)
            .background(Color.risoPaper)
    }

    func testRepeatBoardCTACollapsedLight() {
        assertSnapshot(of: collapsedRepeatCTA(), as: .image(layout: .fixed(width: 393, height: 90), traits: lightTraits), record: recordMode)
    }

    func testRepeatBoardCTACollapsedDark() {
        assertSnapshot(of: collapsedRepeatCTA(), as: .image(layout: .fixed(width: 393, height: 90), traits: darkTraits), record: recordMode)
    }

    // MARK: - RisoRepeatBoardCTA — expanded (cadence picker visible)
    //
    // `RisoRepeatBoardCTA.init(initiallyExpanded:)` seeds the private
    // `@State` so the expanded shape renders deterministically without
    // simulating a real tap — the SAME view, not a hand-rolled stand-in.

    private func expandedRepeatCTA() -> some View {
        RisoRepeatBoardCTA(initiallyExpanded: true, initialCadence: .weekly, onConfirm: { _ in })
            .padding(Riso.gutter)
            .background(Color.risoPaper)
    }

    func testRepeatBoardCTAExpandedLight() {
        assertSnapshot(of: expandedRepeatCTA(), as: .image(layout: .fixed(width: 393, height: 170), traits: lightTraits), record: recordMode)
    }

    func testRepeatBoardCTAExpandedDark() {
        assertSnapshot(of: expandedRepeatCTA(), as: .image(layout: .fixed(width: 393, height: 170), traits: darkTraits), record: recordMode)
    }
}
