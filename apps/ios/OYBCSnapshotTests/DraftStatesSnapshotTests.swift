import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for the new draft-board surfaces
/// (bugfix/draft-board-task-leakage): a DRAFT core board is never playable,
/// so the core-timeframe grid shows a "Resume draft" card and the
/// core-window pager shows a "Resume draft" setup prompt.
final class DraftStatesSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    /// Pinned reference date so the grid's expiry/window math is deterministic.
    private let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 4; c.hour = 12
        c.calendar = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    /// The daily slot carries a DRAFT core board → renders the "Resume draft"
    /// card; the others have no board → "Ready".
    private func draftSlots() -> [CoreBoardSlot] {
        let draftBoard = SnapshotFixtures.makeBoard(
            id: "draft-daily",
            name: "Today",
            timeframe: .daily,
            status: .draft,
            startDate: "2026-05-04T00:00:00.000",
            endDate: "2026-05-04T23:59:59.999",
            isCore: true
        )
        return [
            CoreBoardSlot(timeframe: .daily, windowStart: "2026-05-04T00:00:00.000", windowEnd: "2026-05-04T23:59:59.999", windowLabel: "Today", currentBoard: draftBoard),
            CoreBoardSlot(timeframe: .weekly, windowStart: "2026-05-04T00:00:00.000", windowEnd: "2026-05-10T23:59:59.999", windowLabel: "Week of May 4 – 10, 2026", currentBoard: nil),
            CoreBoardSlot(timeframe: .monthly, windowStart: "2026-05-01T00:00:00.000", windowEnd: "2026-05-31T23:59:59.999", windowLabel: "May 2026", currentBoard: nil),
            CoreBoardSlot(timeframe: .yearly, windowStart: "2026-01-01T00:00:00.000", windowEnd: "2026-12-31T23:59:59.999", windowLabel: "2026", currentBoard: nil),
        ]
    }

    private func gridView() -> some View {
        RisoCoreTimeframeGrid(slots: draftSlots(), now: now, onSelect: { _, _ in })
            .padding(16)
            .background(Color.risoPaper)
    }

    func testCoreGridWithDraftSlotLight() {
        assertSnapshot(of: gridView(), as: .image(layout: .fixed(width: 393, height: 180)), record: recordMode)
    }

    func testCoreGridWithDraftSlotDark() {
        assertSnapshot(
            of: gridView(),
            as: .image(layout: .fixed(width: 393, height: 180), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    private func resumePrompt() -> some View {
        CoreBoardSetupPromptView(
            label: "Today",
            isPast: false,
            resumeDraft: true,
            onSetUp: {}
        )
    }

    func testSetupPromptResumeDraftLight() {
        assertSnapshot(of: resumePrompt(), as: .image(layout: .fixed(width: 393, height: 360)), record: recordMode)
    }

    func testSetupPromptResumeDraftDark() {
        assertSnapshot(
            of: resumePrompt(),
            as: .image(layout: .fixed(width: 393, height: 360), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }
}
