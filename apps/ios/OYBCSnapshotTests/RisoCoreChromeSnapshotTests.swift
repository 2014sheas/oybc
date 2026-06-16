import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Riso-reskinned core-board pager chrome.
///
/// Snapshots the three pure prop-driven leaf views:
///   - `CoreBoardWindowBarView` — prev / label / next / list-button bar.
///   - `CoreBoardWindowCellView` — browser cell in filled, empty, current,
///     and past-empty variants.
///   - `CoreBoardSetupPromptView` — empty-window prompt (Set up / Backfill).
///
/// Views that self-load from `AppDatabase.shared` are NOT snapshotted here:
///   - `CoreBoardWindowView` embeds `BoardPlayView` (which runs GRDB queries
///     via `CoreBoardWindowViewModel`). Snapshot coverage deferred until the
///     test harness supports in-memory DB injection.
///   - `CoreBoardBrowserView` uses `CoreBoardBrowserViewModel` (GRDB + AuthService).
///     The leaf `CoreBoardWindowCellView` it renders IS covered here instead.
///   - `CellSwapSheet` is covered indirectly — its rows use `RisoTypeBadge` and
///     `RisoButton`, both covered in `RisoKitSnapshotTests`. A full sheet
///     snapshot requires NavigationStack + sheet presentation depth; deferred.
///
/// All dates are pinned (no `Date()`) so snapshots are calendar-stable.
final class RisoCoreChromeSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - CoreBoardWindowBarView

    /// Standard bar with a weekly window label (light mode).
    func testWindowBarLight() {
        let view = CoreBoardWindowBarView(
            label: "Week of May 18 – 24, 2026",
            onPrev: {},
            onNext: {},
            onOpenList: {}
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 60)),
            record: recordMode
        )
    }

    /// Bar in dark ("night press") mode — verifies paper/ink token flip.
    func testWindowBarDark() {
        let view = CoreBoardWindowBarView(
            label: "Week of May 18 – 24, 2026",
            onPrev: {},
            onNext: {},
            onOpenList: {}
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 60),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    /// Long label that forces truncation — verifies `.middle` truncation mode
    /// keeps leading and trailing context readable.
    func testWindowBarLongLabelTruncation() {
        let view = CoreBoardWindowBarView(
            label: "September 2026 (Monthly Window)",
            onPrev: {},
            onNext: {},
            onOpenList: {}
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 60)),
            record: recordMode
        )
    }

    // MARK: - CoreBoardWindowCellView

    /// Filled cell — current window, with a board present. The gold keyline
    /// and gold "CURRENT" badge should appear.
    func testWindowCellFilledCurrent() {
        let board = SnapshotFixtures.makeBoard(
            id: "core-cell-current",
            name: "June Wellness",
            timeframe: .monthly,
            status: .active,
            startDate: "2026-06-01T00:00:00.000Z",
            endDate: "2026-06-30T23:59:59.000Z",
            isCore: true
        )
        let cell = CoreBoardWindowCell(
            windowStart: "2026-06-01T00:00:00.000",
            windowEnd: "2026-06-30T23:59:59.999",
            windowLabel: "June 2026",
            board: board,
            isCurrentWindow: true,
            isPastWindow: false
        )
        let view = CoreBoardWindowCellView(
            cell: cell,
            timeframe: .monthly,
            onOpenBoard: { _ in },
            onCreate: { _, _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200)),
            record: recordMode
        )
    }

    /// Empty cell — current window, no board yet. Dashed "Create June 2026"
    /// CTA with gold outline should appear.
    func testWindowCellEmptyCurrent() {
        let cell = CoreBoardWindowCell(
            windowStart: "2026-06-01T00:00:00.000",
            windowEnd: "2026-06-30T23:59:59.999",
            windowLabel: "June 2026",
            board: nil,
            isCurrentWindow: true,
            isPastWindow: false
        )
        let view = CoreBoardWindowCellView(
            cell: cell,
            timeframe: .monthly,
            onOpenBoard: { _ in },
            onCreate: { _, _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 130)),
            record: recordMode
        )
    }

    /// Empty cell — past window with no board. Muted "PAST WINDOW" badge +
    /// dashed "Backfill May 2026" CTA at reduced opacity.
    func testWindowCellEmptyPast() {
        let cell = CoreBoardWindowCell(
            windowStart: "2026-05-01T00:00:00.000",
            windowEnd: "2026-05-31T23:59:59.999",
            windowLabel: "May 2026",
            board: nil,
            isCurrentWindow: false,
            isPastWindow: true
        )
        let view = CoreBoardWindowCellView(
            cell: cell,
            timeframe: .monthly,
            onOpenBoard: { _ in },
            onCreate: { _, _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 130)),
            record: recordMode
        )
    }

    /// Filled cell — past window with a completed board. Standard ink keyline
    /// (no gold), no badge.
    func testWindowCellFilledPast() {
        let board = SnapshotFixtures.makeBoard(
            id: "core-cell-past",
            name: "May Wellness",
            timeframe: .monthly,
            status: .completed,
            startDate: "2026-05-01T00:00:00.000Z",
            endDate: "2026-05-31T23:59:59.000Z",
            isCore: true
        )
        let cell = CoreBoardWindowCell(
            windowStart: "2026-05-01T00:00:00.000",
            windowEnd: "2026-05-31T23:59:59.999",
            windowLabel: "May 2026",
            board: board,
            isCurrentWindow: false,
            isPastWindow: true
        )
        let view = CoreBoardWindowCellView(
            cell: cell,
            timeframe: .monthly,
            onOpenBoard: { _ in },
            onCreate: { _, _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200)),
            record: recordMode
        )
    }

    /// Dark mode variant — filled current cell.
    func testWindowCellFilledCurrentDark() {
        let board = SnapshotFixtures.makeBoard(
            id: "core-cell-current-dark",
            name: "June Wellness",
            timeframe: .monthly,
            status: .active,
            startDate: "2026-06-01T00:00:00.000Z",
            endDate: "2026-06-30T23:59:59.000Z",
            isCore: true
        )
        let cell = CoreBoardWindowCell(
            windowStart: "2026-06-01T00:00:00.000",
            windowEnd: "2026-06-30T23:59:59.999",
            windowLabel: "June 2026",
            board: board,
            isCurrentWindow: true,
            isPastWindow: false
        )
        let view = CoreBoardWindowCellView(
            cell: cell,
            timeframe: .monthly,
            onOpenBoard: { _ in },
            onCreate: { _, _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 200),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - CoreBoardSetupPromptView

    /// Current window prompt (isPast: false) — Blip happy mood + "Set up" CTA.
    func testSetupPromptCurrentLight() {
        let view = CoreBoardSetupPromptView(
            label: "June 2026",
            isPast: false,
            onSetUp: {}
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 380)),
            record: recordMode
        )
    }

    /// Past window prompt (isPast: true) — Blip calm mood + "Backfill" CTA.
    func testSetupPromptPastLight() {
        let view = CoreBoardSetupPromptView(
            label: "May 2026",
            isPast: true,
            onSetUp: {}
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 380)),
            record: recordMode
        )
    }

    /// Dark mode variant of the current-window prompt.
    func testSetupPromptCurrentDark() {
        let view = CoreBoardSetupPromptView(
            label: "June 2026",
            isPast: false,
            onSetUp: {}
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 380),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    /// Short label (daily "Today") — verifies copy renders correctly at
    /// the common daily-pager case.
    func testSetupPromptDailyToday() {
        let view = CoreBoardSetupPromptView(
            label: "Today",
            isPast: false,
            onSetUp: {}
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 380)),
            record: recordMode
        )
    }
}
