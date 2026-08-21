import XCTest
@testable import OYBC

/// Unit tests for the iOS port of the Recurring Boards algorithm — parity
/// with `packages/shared/tests/algorithms/recurringBoards.test.ts`.
///
/// Both implementations are line-for-line ports of the same shared design
/// (docs/ARCHITECTURE.md §Phase 6). Any divergence here would cause the
/// banner to surface different entries on iOS vs web for the same data.
/// This suite pins the invariants the mirror relies on.
final class RecurringBoardsTests: XCTestCase {

    // MARK: - Fixtures

    // Defaults are all-true post-6.1d, so prefsAllEnabled is just .defaults
    // (kept as a named constant for test readability). prefsNoneEnabled is an
    // explicit override for the disabled-prefs test cases.
    private let prefsAllEnabled: UserPreferences = .defaults

    private let prefsNoneEnabled: UserPreferences = {
        var p = UserPreferences.defaults
        p.recurringDailyEnabled = false
        p.recurringWeeklyEnabled = false
        p.recurringMonthlyEnabled = false
        p.recurringYearlyEnabled = false
        return p
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour
        c.calendar = Calendar.current
        c.timeZone = TimeZone.current
        return Calendar.current.date(from: c)!
    }

    /// Builds a `Board` whose `startDate`/`endDate` match the boundary helper
    /// for the given timeframe + reference date — i.e. a board that covers
    /// the same window the detection algorithm will compute for `referenceDate`.
    ///
    /// `Board` has no memberwise init (its custom `init(from:)` for Codable
    /// suppresses the synthesized one in the main type body). Rather than
    /// touch the production model just to add a test-only init, we build
    /// the JSON dict and decode through `JSONDecoder` — same path remote
    /// payloads take, exercising the same Codable surface.
    private func boardForWindow(
        timeframe: Timeframe,
        referenceDate: Date,
        id: String? = nil,
        status: BoardStatus = .active,
        isDeleted: Bool = false,
        isCore: Bool = false
    ) -> Board {
        let window = computeTimeframeBoundaries(
            timeframe: timeframe,
            referenceDate: referenceDate,
            weekStartDay: "monday"
        )!
        let dict: [String: Any] = [
            "id": id ?? "board-\(timeframe.rawValue)-\(wizardLocalISOString(window.start))",
            "userId": "u1",
            "name": "\(timeframe.rawValue) board",
            "status": status.rawValue,
            "boardSize": 5,
            "timeframe": timeframe.rawValue,
            "startDate": wizardLocalISOString(window.start),
            "endDate": wizardLocalISOString(window.end),
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": true,
            "totalTasks": 25,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-05-01T00:00:00.000",
            "updatedAt": "2026-05-01T00:00:00.000",
            "version": 1,
            "isDeleted": isDeleted,
            // Default non-core so each test opts in to suppression
            // explicitly with `isCore: true`. Surfaces the Phase 6.1
            // semantic in the test source instead of hiding it in the
            // fixture.
            "isCore": isCore,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - parentTimeframesByChild

    func testParentTimeframesEncodesCorrectHierarchy() {
        XCTAssertEqual(parentTimeframesByChild[.daily], [.weekly, .monthly, .yearly])
        XCTAssertEqual(parentTimeframesByChild[.weekly], [.monthly, .yearly])
        XCTAssertEqual(parentTimeframesByChild[.monthly], [.yearly])
        XCTAssertEqual(parentTimeframesByChild[.yearly], [])
        XCTAssertEqual(parentTimeframesByChild[.custom], [])
    }

    // MARK: - findPendingRecurringBoards

    func testNoEntriesWhenAllFlagsDisabled() {
        let result = findPendingRecurringBoards(
            boards: [],
            prefs: prefsNoneEnabled,
            now: date(2026, 5, 1)
        )
        XCTAssertEqual(result, [])
    }

    func testSkipsDisabledTimeframesEvenWhenNoBoardsExist() {
        var prefs = prefsNoneEnabled
        prefs.recurringDailyEnabled = true
        let result = findPendingRecurringBoards(
            boards: [],
            prefs: prefs,
            now: date(2026, 5, 1)
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.timeframe, .daily)
    }

    func testReturnsAllFourEntriesWhenAllEnabledAndNoBoards() {
        let result = findPendingRecurringBoards(
            boards: [],
            prefs: prefsAllEnabled,
            now: date(2026, 5, 1)
        )
        XCTAssertEqual(result.map { $0.timeframe }, [.yearly, .monthly, .weekly, .daily])
    }

    func testOrdersLongestWindowFirst() {
        let result = findPendingRecurringBoards(
            boards: [],
            prefs: prefsAllEnabled,
            now: date(2026, 5, 1)
        )
        let order = result.map { $0.timeframe }
        XCTAssertEqual(order, [.yearly, .monthly, .weekly, .daily])
    }

    func testSuppressesDailyWhenTodayHasACoreBoard() {
        let now = date(2026, 5, 1)
        let todaysDaily = boardForWindow(timeframe: .daily, referenceDate: now, isCore: true)
        let result = findPendingRecurringBoards(
            boards: [todaysDaily],
            prefs: prefsAllEnabled,
            now: now
        )
        let timeframes = result.map { $0.timeframe }
        XCTAssertFalse(timeframes.contains(.daily))
        XCTAssertTrue(timeframes.contains(.weekly))
    }

    func testDoesNotSuppressWhenOnlyNonCoreDailyExists() {
        // Regression: an ad-hoc daily board (created from Create tab
        // without going through the banner) used to silently dismiss
        // the suggestion. Now it must not.
        let now = date(2026, 5, 1)
        let adhoc = boardForWindow(timeframe: .daily, referenceDate: now) // isCore: false default
        let result = findPendingRecurringBoards(
            boards: [adhoc],
            prefs: prefsAllEnabled,
            now: now
        )
        XCTAssertTrue(result.contains { $0.timeframe == .daily })
    }

    func testSuppressesDailyWhenCoreExistsEvenAlongsideNonCore() {
        let now = date(2026, 5, 1)
        let adhoc = boardForWindow(timeframe: .daily, referenceDate: now, id: "adhoc")
        let core = boardForWindow(timeframe: .daily, referenceDate: now, id: "core", isCore: true)
        let result = findPendingRecurringBoards(
            boards: [adhoc, core],
            prefs: prefsAllEnabled,
            now: now
        )
        XCTAssertFalse(result.contains { $0.timeframe == .daily })
    }

    func testDoesNotSuppressDailyWhenOnlyYesterdayHasABoard() {
        let yesterday = date(2026, 5, 1)
        let today = date(2026, 5, 2)
        let yesterdaysDaily = boardForWindow(timeframe: .daily, referenceDate: yesterday)
        let result = findPendingRecurringBoards(
            boards: [yesterdaysDaily],
            prefs: prefsAllEnabled,
            now: today
        )
        XCTAssertTrue(result.contains { $0.timeframe == .daily })
    }

    func testTreatsSoftDeletedBoardsAsAbsent() {
        let now = date(2026, 5, 1)
        let deletedDaily = boardForWindow(
            timeframe: .daily, referenceDate: now, isDeleted: true
        )
        let result = findPendingRecurringBoards(
            boards: [deletedDaily],
            prefs: prefsAllEnabled,
            now: now
        )
        XCTAssertTrue(result.contains { $0.timeframe == .daily })
    }

    func testJanuaryFirstReturnsAllFourPending() {
        let jan1 = date(2026, 1, 1)
        let result = findPendingRecurringBoards(
            boards: [],
            prefs: prefsAllEnabled,
            now: jan1
        )
        XCTAssertEqual(result.map { $0.timeframe }, [.yearly, .monthly, .weekly, .daily])
    }

    // MARK: - getParentBoards

    func testYearlyHasNoParents() {
        let yearly = boardForWindow(timeframe: .yearly, referenceDate: date(2026, 5, 1))
        XCTAssertTrue(
            getParentBoards(childTimeframe: .yearly, allActiveBoards: [yearly], now: date(2026, 5, 1)).isEmpty
        )
    }

    func testCustomHasNoParents() {
        XCTAssertTrue(
            getParentBoards(childTimeframe: .custom, allActiveBoards: [], now: date(2026, 5, 1)).isEmpty
        )
    }

    func testDailyReturnsActiveWeeklyMonthlyYearly() {
        let now = date(2026, 5, 15)
        let weekly = boardForWindow(timeframe: .weekly, referenceDate: now, id: "weekly")
        let monthly = boardForWindow(timeframe: .monthly, referenceDate: now, id: "monthly")
        let yearly = boardForWindow(timeframe: .yearly, referenceDate: now, id: "yearly")
        let result = getParentBoards(
            childTimeframe: .daily,
            allActiveBoards: [weekly, monthly, yearly],
            now: now
        )
        XCTAssertEqual(Set(result.map { $0.id }), ["weekly", "monthly", "yearly"])
    }

    func testWeeklyReturnsOnlyMonthlyAndYearly() {
        let now = date(2026, 5, 15)
        let otherWeekly = boardForWindow(timeframe: .weekly, referenceDate: now, id: "weekly")
        let monthly = boardForWindow(timeframe: .monthly, referenceDate: now, id: "monthly")
        let yearly = boardForWindow(timeframe: .yearly, referenceDate: now, id: "yearly")
        let result = getParentBoards(
            childTimeframe: .weekly,
            allActiveBoards: [otherWeekly, monthly, yearly],
            now: now
        )
        XCTAssertEqual(Set(result.map { $0.id }), ["monthly", "yearly"])
    }

    func testExcludesDeletedParents() {
        let monthly = boardForWindow(
            timeframe: .monthly,
            referenceDate: date(2026, 5, 15),
            isDeleted: true
        )
        XCTAssertTrue(
            getParentBoards(
                childTimeframe: .daily,
                allActiveBoards: [monthly],
                now: date(2026, 5, 15)
            ).isEmpty
        )
    }

    func testExcludesNonActiveParents() {
        let now = date(2026, 5, 15)
        let draft = boardForWindow(timeframe: .monthly, referenceDate: now, id: "draft", status: .draft)
        let completed = boardForWindow(timeframe: .monthly, referenceDate: now, id: "completed", status: .completed)
        let archived = boardForWindow(timeframe: .monthly, referenceDate: now, id: "archived", status: .archived)
        XCTAssertTrue(
            getParentBoards(
                childTimeframe: .daily,
                allActiveBoards: [draft, completed, archived],
                now: now
            ).isEmpty
        )
    }

    func testExcludesParentsWhoseWindowHasExpired() {
        let lastMonth = date(2026, 4, 1)
        let today = date(2026, 5, 15)
        let lastMonthsMonthly = boardForWindow(timeframe: .monthly, referenceDate: lastMonth)
        XCTAssertTrue(
            getParentBoards(
                childTimeframe: .daily,
                allActiveBoards: [lastMonthsMonthly],
                now: today
            ).isEmpty
        )
    }

    func testDoesNotReturnSiblingTimeframeBoards() {
        let sibling = boardForWindow(
            timeframe: .daily, referenceDate: date(2026, 5, 15), id: "sibling"
        )
        XCTAssertTrue(
            getParentBoards(
                childTimeframe: .daily,
                allActiveBoards: [sibling],
                now: date(2026, 5, 15)
            ).isEmpty
        )
    }

    // MARK: - isFreshlyDealtBoard (Task Pools + Recurring Boards Rework, P6)

    func testIsFreshlyDealtBoard_OddBoardWithFreeCenter_ZeroCompleted_IsFresh() {
        XCTAssertTrue(isFreshlyDealtBoard(completedTasks: 0, boardSize: 5, centerSquareType: .free))
    }

    func testIsFreshlyDealtBoard_OddBoardWithFreeCenter_OnlyAutoCompletedCenter_StillFresh() {
        // The FREE center auto-completes at spawn via derivation — that one
        // completion must not disqualify the board from "freshly dealt".
        XCTAssertTrue(isFreshlyDealtBoard(completedTasks: 1, boardSize: 5, centerSquareType: .free))
    }

    func testIsFreshlyDealtBoard_OddBoardWithFreeCenter_OneRealCompletion_NotFresh() {
        // Baseline is 1 (the auto-completed center); a second completion is
        // real user progress.
        XCTAssertFalse(isFreshlyDealtBoard(completedTasks: 2, boardSize: 5, centerSquareType: .free))
    }

    func testIsFreshlyDealtBoard_OddBoardWithChosenCenter_ZeroCompleted_IsFresh() {
        // A CHOSEN center is an ordinary task square, not an auto-complete —
        // baseline is 0, same as an even board.
        XCTAssertTrue(isFreshlyDealtBoard(completedTasks: 0, boardSize: 5, centerSquareType: .chosen))
    }

    func testIsFreshlyDealtBoard_OddBoardWithChosenCenter_OneCompletion_NotFresh() {
        XCTAssertFalse(isFreshlyDealtBoard(completedTasks: 1, boardSize: 5, centerSquareType: .chosen))
    }

    func testIsFreshlyDealtBoard_EvenBoard_ZeroCompleted_IsFresh() {
        // No center at all on an even board — baseline is 0 regardless of
        // `centerSquareType`.
        XCTAssertTrue(isFreshlyDealtBoard(completedTasks: 0, boardSize: 4, centerSquareType: .free))
    }

    func testIsFreshlyDealtBoard_EvenBoard_OneCompletion_NotFresh() {
        XCTAssertFalse(isFreshlyDealtBoard(completedTasks: 1, boardSize: 4, centerSquareType: .free))
    }

    func testIsFreshlyDealtBoard_OddBoardWithNoneCenter_ZeroCompleted_IsFresh() {
        XCTAssertTrue(isFreshlyDealtBoard(completedTasks: 0, boardSize: 3, centerSquareType: .none))
    }

    func testIsFreshlyDealtBoard_OddBoardWithNoneCenter_OneCompletion_NotFresh() {
        XCTAssertFalse(isFreshlyDealtBoard(completedTasks: 1, boardSize: 3, centerSquareType: .none))
    }
}
