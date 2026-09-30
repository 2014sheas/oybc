import XCTest
@testable import OYBC

/// `RecurringTemplateCard.renewalDayText` / `.formatMetaLine` — the
/// compact roster row's meta line (Profile reorg PR3,
/// `design_handoff_profile_reorg/README.md` §4 "REPEATING BOARDS": `{size}
/// board · {n}-task pool · renews {day}` or `… · paused`). Pure + tested so
/// the copy can't silently drift from the toggle/pause state or the user's
/// week-start preference.
final class RecurringTemplateMetaTests: XCTestCase {

    // MARK: - renewalDayText

    func test_weekly_honorsWeekStartMonday() {
        XCTAssertEqual(
            RecurringTemplateCard.renewalDayText(timeframe: .weekly, weekStartDay: .monday),
            "Mondays"
        )
    }

    func test_weekly_honorsWeekStartSunday() {
        XCTAssertEqual(
            RecurringTemplateCard.renewalDayText(timeframe: .weekly, weekStartDay: .sunday),
            "Sundays"
        )
    }

    func test_monthly_fixedDay_ignoresWeekStart() {
        XCTAssertEqual(RecurringTemplateCard.renewalDayText(timeframe: .monthly, weekStartDay: .monday), "the 1st")
        XCTAssertEqual(RecurringTemplateCard.renewalDayText(timeframe: .monthly, weekStartDay: .sunday), "the 1st")
    }

    func test_daily_fixedDay() {
        XCTAssertEqual(RecurringTemplateCard.renewalDayText(timeframe: .daily, weekStartDay: .monday), "every morning")
    }

    func test_yearly_fixedDay() {
        XCTAssertEqual(RecurringTemplateCard.renewalDayText(timeframe: .yearly, weekStartDay: .sunday), "Jan 1")
    }

    // MARK: - formatMetaLine

    func test_active_weekly_mondayStart() {
        XCTAssertEqual(
            RecurringTemplateCard.formatMetaLine(
                boardSize: 5, taskCount: 9, isActive: true, timeframe: .weekly, weekStartDay: .monday
            ),
            "5×5 board · 9-task pool · renews Mondays"
        )
    }

    func test_active_weekly_sundayStart() {
        XCTAssertEqual(
            RecurringTemplateCard.formatMetaLine(
                boardSize: 5, taskCount: 9, isActive: true, timeframe: .weekly, weekStartDay: .sunday
            ),
            "5×5 board · 9-task pool · renews Sundays"
        )
    }

    /// Paused never shows a renewal day, regardless of timeframe/week start
    /// — there isn't one until resumed.
    func test_paused_omitsRenewalDay() {
        XCTAssertEqual(
            RecurringTemplateCard.formatMetaLine(
                boardSize: 3, taskCount: 8, isActive: false, timeframe: .weekly, weekStartDay: .monday
            ),
            "3×3 board · 8-task pool · paused"
        )
    }

    func test_active_monthly() {
        XCTAssertEqual(
            RecurringTemplateCard.formatMetaLine(
                boardSize: 4, taskCount: 16, isActive: true, timeframe: .monthly, weekStartDay: .monday
            ),
            "4×4 board · 16-task pool · renews the 1st"
        )
    }
}
