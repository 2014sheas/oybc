import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for the Riso-reskinned `CoreBoardsSectionView` (the
/// enabled-recurring-timeframe section on the Create hub / Boards tab).
/// Renders the REAL view with pinned window labels (no `Date()`).
final class RisoCoreBoardsSectionSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func slots() -> [CoreBoardSlot] {
        [
            CoreBoardSlot(timeframe: .daily, windowStart: "2026-05-04T00:00:00.000", windowEnd: "2026-05-04T23:59:59.999", windowLabel: "Today", currentBoard: nil),
            CoreBoardSlot(timeframe: .weekly, windowStart: "2026-05-04T00:00:00.000", windowEnd: "2026-05-10T23:59:59.999", windowLabel: "Week of May 4 – 10, 2026", currentBoard: nil),
            CoreBoardSlot(timeframe: .monthly, windowStart: "2026-05-01T00:00:00.000", windowEnd: "2026-05-31T23:59:59.999", windowLabel: "May 2026", currentBoard: nil),
        ]
    }

    /// Issue #321 — the Create-hub subtitle passed here exercises the new
    /// `subtitle` prop at the component level; height bumped from 320 to
    /// fit the extra caption line.
    private func view() -> some View {
        CoreBoardsSectionView(
            slots: slots(),
            onSelect: { _ in },
            subtitle: "Your standard board for each time period."
        )
            .padding(16)
            .background(Color.risoPaper)
    }

    func testCoreBoardsSectionLight() {
        assertSnapshot(of: view(), as: .image(layout: .fixed(width: 393, height: 340)), record: recordMode)
    }

    func testCoreBoardsSectionDark() {
        assertSnapshot(
            of: view(),
            as: .image(layout: .fixed(width: 393, height: 340), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }
}
