import XCTest
@testable import OYBC

/// Unit tests for `NotificationPlanner.desiredNotifications` — the pure core of
/// the Phase 7 local-notifications feature. Every case injects `now` so the
/// plan is fully deterministic (no wall-clock dependency). Mirrors the
/// `RecurringBoardsTests` style. See docs/NOTIFICATIONS.md.
final class NotificationPlannerTests: XCTestCase {

    // MARK: - Fixtures

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = hour; c.minute = minute
        c.calendar = Calendar.current
        c.timeZone = TimeZone.current
        return Calendar.current.date(from: c)!
    }

    /// Builds prefs with notifications on by default; toggle individual flags.
    private func prefs(
        notificationsEnabled: Bool = true,
        expiringReminders: Bool = true,
        recurringWindowReminders: Bool = true,
        dailyPlayReminderEnabled: Bool = false,
        dailyPlayReminderTime: String = "20:00",
        recurringDailyEnabled: Bool = true,
        recurringWeeklyEnabled: Bool = true,
        recurringMonthlyEnabled: Bool = true,
        recurringYearlyEnabled: Bool = true
    ) -> UserPreferences {
        var p = UserPreferences.defaults
        p.notificationsEnabled = notificationsEnabled
        p.expiringReminders = expiringReminders
        p.recurringWindowReminders = recurringWindowReminders
        p.dailyPlayReminderEnabled = dailyPlayReminderEnabled
        p.dailyPlayReminderTime = dailyPlayReminderTime
        p.recurringDailyEnabled = recurringDailyEnabled
        p.recurringWeeklyEnabled = recurringWeeklyEnabled
        p.recurringMonthlyEnabled = recurringMonthlyEnabled
        p.recurringYearlyEnabled = recurringYearlyEnabled
        return p
    }

    /// Board builder taking explicit start/end Dates (decoded through Codable,
    /// the same path remote payloads take — `Board` has no memberwise init).
    private func board(
        id: String,
        timeframe: Timeframe,
        endDate: Date,
        startDate: Date? = nil,
        status: BoardStatus = .active,
        isDeleted: Bool = false,
        isCore: Bool = false,
        name: String = "Board"
    ) -> Board {
        let start = startDate ?? endDate.addingTimeInterval(-86_400)
        let dict: [String: Any] = [
            "id": id,
            "userId": "u1",
            "name": name,
            "status": status.rawValue,
            "boardSize": 5,
            "timeframe": timeframe.rawValue,
            "startDate": wizardLocalISOString(start),
            "endDate": wizardLocalISOString(endDate),
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": true,
            "totalTasks": 25,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-05-01T00:00:00.000",
            "updatedAt": "2026-05-01T00:00:00.000",
            "version": 1,
            "isDeleted": isDeleted,
            "isCore": isCore,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    /// Extracts the absolute fire `Date` from a `.calendar` trigger.
    private func calendarDate(_ n: PlannedNotification) -> Date? {
        if case let .calendar(date) = n.trigger { return date }
        return nil
    }

    // MARK: - Master gate

    func testMasterDisabledReturnsEmpty() {
        let now = date(2026, 6, 15)
        let b = board(id: "b1", timeframe: .weekly, endDate: date(2026, 6, 21, hour: 23, minute: 59))
        let result = NotificationPlanner.desiredNotifications(
            boards: [b], prefs: prefs(notificationsEnabled: false), now: now
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Board expiring soon

    func testExpiryFiresAt9amDayBeforeDeadline() {
        let now = date(2026, 6, 15)
        // Weekly board expiring Sunday Jun 21 23:59.
        let b = board(id: "b1", timeframe: .weekly,
                      endDate: date(2026, 6, 21, hour: 23, minute: 59),
                      name: "Weekly Wellness")
        let result = NotificationPlanner.desiredNotifications(
            boards: [b], prefs: prefs(), now: now
        ).filter { $0.category == .expiry }

        XCTAssertEqual(result.count, 1)
        let n = result[0]
        XCTAssertEqual(n.identifier, "expiry-b1")
        XCTAssertEqual(n.userInfo["boardId"], "b1")
        // Fire 9am on the day before the deadline (Jun 20).
        let fire = calendarDate(n)!
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 20)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
    }

    func testExpirySkipsDailyBoards() {
        let now = date(2026, 6, 15)
        let b = board(id: "d1", timeframe: .daily,
                      endDate: date(2026, 6, 16, hour: 23, minute: 59))
        let result = NotificationPlanner.desiredNotifications(
            boards: [b], prefs: prefs(), now: now
        ).filter { $0.category == .expiry }
        XCTAssertTrue(result.isEmpty)
    }

    func testExpiryIncludesCustomBoardsWithDeadline() {
        let now = date(2026, 6, 15)
        let b = board(id: "c1", timeframe: .custom,
                      endDate: date(2026, 6, 25, hour: 23, minute: 59))
        let result = NotificationPlanner.desiredNotifications(
            boards: [b], prefs: prefs(), now: now
        ).filter { $0.category == .expiry }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].identifier, "expiry-c1")
    }

    func testExpirySkipsDeletedAndNonActive() {
        let now = date(2026, 6, 15)
        let deleted = board(id: "del", timeframe: .weekly,
                            endDate: date(2026, 6, 21, hour: 23, minute: 59), isDeleted: true)
        let draft = board(id: "draft", timeframe: .weekly,
                          endDate: date(2026, 6, 21, hour: 23, minute: 59), status: .draft)
        let completed = board(id: "done", timeframe: .weekly,
                              endDate: date(2026, 6, 21, hour: 23, minute: 59), status: .completed)
        let result = NotificationPlanner.desiredNotifications(
            boards: [deleted, draft, completed], prefs: prefs(), now: now
        ).filter { $0.category == .expiry }
        XCTAssertTrue(result.isEmpty)
    }

    func testExpiryExcludesPastFireDate() {
        let now = date(2026, 6, 15)
        // Deadline today → fire would be yesterday 9am (in the past).
        let b = board(id: "b1", timeframe: .weekly,
                      endDate: date(2026, 6, 15, hour: 23, minute: 59))
        let result = NotificationPlanner.desiredNotifications(
            boards: [b], prefs: prefs(), now: now
        ).filter { $0.category == .expiry }
        XCTAssertTrue(result.isEmpty)
    }

    func testExpiryExcludesBeyondHorizon() {
        let now = date(2026, 6, 15)
        // 60 days out — beyond the 30-day horizon.
        let b = board(id: "b1", timeframe: .monthly,
                      endDate: date(2026, 8, 14, hour: 23, minute: 59))
        let result = NotificationPlanner.desiredNotifications(
            boards: [b], prefs: prefs(), now: now
        ).filter { $0.category == .expiry }
        XCTAssertTrue(result.isEmpty)
    }

    func testExpiryRespectsExpiringRemindersFlag() {
        let now = date(2026, 6, 15)
        let b = board(id: "b1", timeframe: .weekly,
                      endDate: date(2026, 6, 21, hour: 23, minute: 59))
        let result = NotificationPlanner.desiredNotifications(
            boards: [b], prefs: prefs(expiringReminders: false), now: now
        ).filter { $0.category == .expiry }
        XCTAssertTrue(result.isEmpty)
    }

    func testExpiryBudgetCapsAt50WithStableTieBreak() {
        let now = date(2026, 6, 15)
        // 51 boards, all the same deadline → identical fire date. Tie-break by
        // id ascending keeps b00…b49, drops b50.
        let deadline = date(2026, 6, 17, hour: 23, minute: 59)
        let boards = (0...50).map { i in
            board(id: String(format: "b%02d", i), timeframe: .weekly, endDate: deadline)
        }
        let result = NotificationPlanner.desiredNotifications(
            boards: boards, prefs: prefs(), now: now
        ).filter { $0.category == .expiry }

        XCTAssertEqual(result.count, 50)
        let ids = Set(result.map { $0.identifier })
        XCTAssertTrue(ids.contains("expiry-b00"))
        XCTAssertTrue(ids.contains("expiry-b49"))
        XCTAssertFalse(ids.contains("expiry-b50"))
    }

    // MARK: - New recurring window

    func testRecurringWindowProducesWeeklyMonthlyYearlyNotDaily() {
        // 2026-06-15 is a Monday; weekStart monday.
        let now = date(2026, 6, 15)
        let result = NotificationPlanner.desiredNotifications(
            boards: [], prefs: prefs(), now: now
        ).filter { $0.category == .recurringWindow }

        let timeframes = Set(result.compactMap { $0.userInfo["timeframe"] })
        XCTAssertEqual(timeframes, ["weekly", "monthly", "yearly"])
        XCTAssertFalse(timeframes.contains("daily"))
    }

    func testRecurringWindowWeeklyFiresAt9amNextWindowStart() {
        let now = date(2026, 6, 15)
        let result = NotificationPlanner.desiredNotifications(
            boards: [], prefs: prefs(), now: now
        ).filter { $0.userInfo["timeframe"] == "weekly" }
        XCTAssertEqual(result.count, 1)
        // Next weekly window starts Mon Jun 22; fire 9am that day.
        let fire = calendarDate(result[0])!
        let comps = Calendar.current.dateComponents([.month, .day, .hour], from: fire)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 22)
        XCTAssertEqual(comps.hour, 9)
    }

    func testRecurringWindowSuppressedWhenNextCoreBoardExists() {
        let now = date(2026, 6, 15)
        // Build a core weekly board for the NEXT window (starts Jun 22).
        let nextWindow = computeTimeframeBoundaries(
            timeframe: .weekly, referenceDate: date(2026, 6, 22), weekStartDay: "monday"
        )!
        let existing = board(
            id: "next-wk", timeframe: .weekly,
            endDate: nextWindow.end, startDate: nextWindow.start, isCore: true
        )
        let result = NotificationPlanner.desiredNotifications(
            boards: [existing], prefs: prefs(), now: now
        ).filter { $0.userInfo["timeframe"] == "weekly" && $0.category == .recurringWindow }
        XCTAssertTrue(result.isEmpty)
    }

    func testRecurringWindowRespectsPerTimeframeFlag() {
        let now = date(2026, 6, 15)
        let result = NotificationPlanner.desiredNotifications(
            boards: [], prefs: prefs(recurringWeeklyEnabled: false), now: now
        ).filter { $0.category == .recurringWindow }
        let timeframes = Set(result.compactMap { $0.userInfo["timeframe"] })
        XCTAssertEqual(timeframes, ["monthly", "yearly"])
    }

    func testRecurringWindowRespectsMasterCategoryFlag() {
        let now = date(2026, 6, 15)
        let result = NotificationPlanner.desiredNotifications(
            boards: [], prefs: prefs(recurringWindowReminders: false), now: now
        ).filter { $0.category == .recurringWindow }
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Daily play reminder

    func testDailyReminderWhenEnabled() {
        let now = date(2026, 6, 15)
        let result = NotificationPlanner.desiredNotifications(
            boards: [],
            prefs: prefs(
                expiringReminders: false,
                recurringWindowReminders: false,
                dailyPlayReminderEnabled: true,
                dailyPlayReminderTime: "07:30"
            ),
            now: now
        )
        XCTAssertEqual(result.count, 1)
        let n = result[0]
        XCTAssertEqual(n.identifier, "daily-play-reminder")
        XCTAssertEqual(n.category, .dailyReminder)
        XCTAssertEqual(n.trigger, .dailyTime(hour: 7, minute: 30))
    }

    func testDailyReminderOmittedWhenDisabled() {
        let now = date(2026, 6, 15)
        let result = NotificationPlanner.desiredNotifications(
            boards: [],
            prefs: prefs(
                expiringReminders: false,
                recurringWindowReminders: false,
                dailyPlayReminderEnabled: false
            ),
            now: now
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testParseReminderTimeRejectsMalformed() {
        XCTAssertNil(NotificationPlanner.parseReminderTime("8pm"))
        XCTAssertNil(NotificationPlanner.parseReminderTime("24:00"))
        XCTAssertNil(NotificationPlanner.parseReminderTime("12:60"))
        XCTAssertEqual(NotificationPlanner.parseReminderTime("06:05").map { [$0.hour, $0.minute] }, [6, 5])
    }
}
