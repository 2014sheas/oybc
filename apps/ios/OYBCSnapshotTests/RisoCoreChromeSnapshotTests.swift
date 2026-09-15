import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Riso core-board pager chrome (masthead
/// rework).
///
/// Snapshots the pure prop-driven leaf views:
///   - `CoreWindowChipView` — the header window chip (resting / open /
///     empty / edit-dimmed, light + dark).
///   - `CoreWindowPositionCaption` — the `‹ August · dots · October ›`
///     row under the grid.
///   - `CoreWindowPickerSheet` — the window-jump half-sheet content
///     (monthly year grid + daily month calendar), with a pinned `now`
///     and a literal `boardsByStart` so tiles are deterministic.
///   - `CoreBoardSetupPromptView` — empty-window prompt (Set up /
///     Backfill; standalone container).
///
/// `CoreBoardWindowView` itself embeds `BoardPlayView` (GRDB queries via
/// `CoreBoardWindowViewModel`) and is NOT snapshotted here.
///
/// All dates are pinned (no `Date()`) so snapshots are calendar-stable.
final class RisoCoreChromeSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    /// Pinned "now" — Sep 15 2026, mid-month, mid-week.
    private var pinnedNow: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 15; comps.hour = 12
        return Calendar.current.date(from: comps)!
    }

    // MARK: - Fixture dots

    /// The resting neighborhood: two past boards, displayed = today
    /// (has board), next empty, further-future empty.
    private var restingDots: [CoreWindowPicker.NeighborhoodDot] {
        [
            .init(offset: -2, windowStart: "a", hasBoard: true, isDisplayed: false, isToday: false),
            .init(offset: -1, windowStart: "b", hasBoard: true, isDisplayed: false, isToday: false),
            .init(offset: 0, windowStart: "c", hasBoard: true, isDisplayed: true, isToday: true),
            .init(offset: 1, windowStart: "d", hasBoard: false, isDisplayed: false, isToday: false),
            .init(offset: 2, windowStart: "e", hasBoard: false, isDisplayed: false, isToday: false),
        ]
    }

    /// Paged-away neighborhood: displayed = empty next window; today's
    /// gold ring sits on the −1 dot.
    private var pagedAwayDots: [CoreWindowPicker.NeighborhoodDot] {
        [
            .init(offset: -2, windowStart: "a", hasBoard: true, isDisplayed: false, isToday: false),
            .init(offset: -1, windowStart: "b", hasBoard: true, isDisplayed: false, isToday: true),
            .init(offset: 0, windowStart: "c", hasBoard: false, isDisplayed: true, isToday: false),
            .init(offset: 1, windowStart: "d", hasBoard: false, isDisplayed: false, isToday: false),
            .init(offset: 2, windowStart: "e", hasBoard: false, isDisplayed: false, isToday: false),
        ]
    }

    private func chipHost<V: View>(_ view: V) -> some View {
        ZStack {
            RisoPaperBackground()
            view.padding(16)
        }
    }

    // MARK: - CoreWindowChipView

    func testWindowChipRestingLight() {
        let view = chipHost(CoreWindowChipView(
            label: "September 2026",
            dots: restingDots,
            accessibilityText: "September 2026, current window. Opens window picker.",
            action: {}
        ))
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 300, height: 70)),
            record: recordMode
        )
    }

    func testWindowChipRestingDark() {
        let view = chipHost(CoreWindowChipView(
            label: "September 2026",
            dots: restingDots,
            accessibilityText: "September 2026, current window. Opens window picker.",
            action: {}
        ))
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 300, height: 70),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    /// Open chip — inverted ink fill, paper text, chevron up.
    func testWindowChipOpen() {
        let view = chipHost(CoreWindowChipView(
            label: "September 2026",
            dots: restingDots,
            isOpen: true,
            accessibilityText: "September 2026, current window. Opens window picker.",
            action: {}
        ))
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 300, height: 70)),
            record: recordMode
        )
    }

    /// Empty window — dashed keyline, no shadow, "· next" label suffix.
    func testWindowChipEmptyWindow() {
        let view = chipHost(CoreWindowChipView(
            label: "October · next",
            dots: pagedAwayDots,
            isEmpty: true,
            accessibilityText: "October. Opens window picker.",
            action: {}
        ))
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 300, height: 70)),
            record: recordMode
        )
    }

    /// Edit mode — 45% opacity, inert.
    func testWindowChipEditDimmed() {
        let view = chipHost(CoreWindowChipView(
            label: "September 2026",
            dots: restingDots,
            isDisabled: true,
            accessibilityText: "September 2026, current window. Opens window picker.",
            action: {}
        ))
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 300, height: 70)),
            record: recordMode
        )
    }

    // MARK: - CoreWindowPositionCaption

    func testPositionCaptionLight() {
        let view = chipHost(CoreWindowPositionCaption(
            prevLabel: "August",
            nextLabel: "October",
            dots: restingDots,
            onPrev: {},
            onNext: {}
        ))
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 60)),
            record: recordMode
        )
    }

    func testPositionCaptionDisabled() {
        let view = chipHost(CoreWindowPositionCaption(
            prevLabel: "August",
            nextLabel: "October",
            dots: restingDots,
            isDisabled: true,
            onPrev: {},
            onNext: {}
        ))
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 60)),
            record: recordMode
        )
    }

    // MARK: - CoreWindowPickerSheet

    /// Boards for the monthly picker page: July sealed (closed), August
    /// completed (done), September active mid-progress (current, gold).
    private var monthlyBoardsByStart: [String: Board] {
        let july = SnapshotFixtures.makeBoard(
            id: "picker-jul", name: "July", boardSize: 3, timeframe: .monthly,
            status: .active,
            startDate: "2026-07-01T00:00:00.000", endDate: "2026-07-31T23:59:59.999",
            isCore: true, sealedAt: "2026-08-01T00:00:00.000", completedTasks: 5
        )
        let august = SnapshotFixtures.makeBoard(
            id: "picker-aug", name: "August", boardSize: 3, timeframe: .monthly,
            status: .completed,
            startDate: "2026-08-01T00:00:00.000", endDate: "2026-08-31T23:59:59.999",
            isCore: true, completedTasks: 9
        )
        let september = SnapshotFixtures.makeBoard(
            id: "picker-sep", name: "September", boardSize: 3, timeframe: .monthly,
            status: .active,
            startDate: "2026-09-01T00:00:00.000", endDate: "2026-09-30T23:59:59.999",
            isCore: true, completedTasks: 4
        )
        return [
            july.startDate: july,
            august.startDate: august,
            september.startDate: september,
        ]
    }

    /// Monthly year grid — exercises closed / done / current(gold,
    /// progress) / next("set up") / further-future / past-empty tiles.
    func testPickerSheetMonthlyLight() {
        let view = CoreWindowPickerSheet(
            timeframe: .monthly,
            weekStartDay: "monday",
            boardsByStart: monthlyBoardsByStart,
            displayedWindowStart: "2026-09-01T00:00:00.000",
            now: pinnedNow,
            onSelect: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 560)),
            record: recordMode
        )
    }

    func testPickerSheetMonthlyDark() {
        let view = CoreWindowPickerSheet(
            timeframe: .monthly,
            weekStartDay: "monday",
            boardsByStart: monthlyBoardsByStart,
            displayedWindowStart: "2026-09-01T00:00:00.000",
            now: pinnedNow,
            onSelect: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 560),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    /// Daily month calendar — 7-column layout with weekday heads +
    /// leading blanks (Sep 2026 starts on a Tuesday → 1 blank).
    func testPickerSheetDailyCalendar() {
        let today = SnapshotFixtures.makeBoard(
            id: "picker-day", name: "Today", boardSize: 3, timeframe: .daily,
            status: .active,
            startDate: "2026-09-15T00:00:00.000", endDate: "2026-09-15T23:59:59.999",
            isCore: true, completedTasks: 2
        )
        let view = CoreWindowPickerSheet(
            timeframe: .daily,
            weekStartDay: "monday",
            boardsByStart: [today.startDate: today],
            displayedWindowStart: "2026-09-15T00:00:00.000",
            now: pinnedNow,
            onSelect: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 620)),
            record: recordMode
        )
    }

    // MARK: - CoreBoardSetupPromptView

    /// Current window prompt (isPast: false) — mini-board art (started) + "Set up" CTA.
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

    /// Past window prompt (isPast: true) — mini-board art (started) + "Backfill" CTA.
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
