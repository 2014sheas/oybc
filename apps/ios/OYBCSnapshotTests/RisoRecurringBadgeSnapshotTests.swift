import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for issue #321's "Recurring" provenance badge
/// (`RisoRecurringBadge`) — both in isolation and composed into
/// `RisoBoardCard` (the Boards-list card), which is DB-free and can be
/// snapshotted directly.
///
/// `BoardPlayView`'s in-header badge placement shares the exact same
/// `RisoRecurringBadge` view + `shouldShow(for:)` predicate exercised
/// here; per `SnapshotFixtures`'s existing note, `BoardPlayView` itself
/// queries `AppDatabase.shared` and isn't yet snapshotted (would need an
/// injected/seeded in-memory instance), so that surface is covered by
/// build + the CLAUDE.md manual relay-to-user convention instead of a
/// snapshot here.
final class RisoRecurringBadgeSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private let lightTraits = UITraitCollection(userInterfaceStyle: .light)
    private let darkTraits  = UITraitCollection(userInterfaceStyle: .dark)

    // MARK: - Badge in isolation

    func testBadgeLight() {
        let view = RisoRecurringBadge()
            .padding(16)
            .background(Color.risoPaper)
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 160, height: 60), traits: lightTraits), record: recordMode)
    }

    func testBadgeDark() {
        let view = RisoRecurringBadge()
            .padding(16)
            .background(Color.risoPaper)
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 160, height: 60), traits: darkTraits), record: recordMode)
    }

    // MARK: - Composed into RisoBoardCard

    private func recurringBoardCard() -> some View {
        let board = SnapshotFixtures.makeBoard(
            id: "b-recurring",
            name: "Weekly Wellness",
            boardSize: 5,
            timeframe: .weekly,
            status: .active,
            spawnedFromTemplateId: "tpl-1"
        )
        return RisoBoardCard(
            board: board, timeframeLabel: "This week · 4 days left", isExpiring: false,
            previewCells: SnapshotFixtures.makePreviewCells(completed: board.completedTasks, size: board.boardSize)
        )
            .padding(Riso.gutter)
            .background(Color.risoPaper)
    }

    func testBoardCardWithRecurringBadgeLight() {
        assertSnapshot(of: recurringBoardCard(), as: .image(layout: .fixed(width: 393, height: 200), traits: lightTraits), record: recordMode)
    }

    func testBoardCardWithRecurringBadgeDark() {
        assertSnapshot(of: recurringBoardCard(), as: .image(layout: .fixed(width: 393, height: 200), traits: darkTraits), record: recordMode)
    }
}
