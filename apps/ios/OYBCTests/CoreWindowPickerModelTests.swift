import XCTest
@testable import OYBC

/// Unit coverage for the pure `CoreWindowPicker` model (core-board
/// surface rework): the chip's ±2-window neighborhood dots, the chip
/// label suffix, the six-state tile mapping, and the calendar-aligned
/// picker pages. Mirrors the web `corePickerTiles.test.ts` cases so the
/// two implementations stay in lockstep (parity rule 6).
final class CoreWindowPickerModelTests: XCTestCase {

    /// Pinned "now" — Sep 15 2026, mid-month.
    private var now: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 15; comps.hour = 12
        return Calendar.current.date(from: comps)!
    }

    private var monthlyToday: String {
        wizardLocalISOString(
            computeTimeframeBoundaries(timeframe: .monthly, referenceDate: now, weekStartDay: "monday")!.start
        )
    }

    private func makeBoard(
        id: String,
        startDate: String,
        status: String = "active",
        sealedAt: String? = nil,
        completedTasks: Int = 4
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": "u1", "name": "B", "status": status,
            "boardSize": 3, "timeframe": "monthly",
            "startDate": startDate, "endDate": startDate,
            "centerSquareType": "none", "isRandomized": false,
            "totalTasks": 9, "completedTasks": completedTasks, "linesCompleted": 0,
            "createdAt": startDate, "updatedAt": startDate, "version": 1,
            "isDeleted": false, "isCore": true,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - Neighborhood

    func test_buildNeighborhood_flagsDisplayedTodayAndBoards() {
        let boards = [monthlyToday: makeBoard(id: "b1", startDate: monthlyToday)]
        let dots = CoreWindowPicker.buildNeighborhood(
            timeframe: .monthly,
            windowStart: monthlyToday,
            todayWindowStart: monthlyToday,
            boardsByStart: boards,
            weekStartDay: "monday"
        )
        XCTAssertEqual(dots.count, 5)
        XCTAssertEqual(dots.map(\.offset), [-2, -1, 0, 1, 2])
        XCTAssertTrue(dots[2].isDisplayed)
        XCTAssertTrue(dots[2].isToday)
        XCTAssertTrue(dots[2].hasBoard)
        XCTAssertFalse(dots[0].hasBoard)
    }

    func test_buildNeighborhood_marksTodayOnNonDisplayedDot() {
        let prev = stepCoreBoardWindow(
            timeframe: .monthly, fromStartIso: monthlyToday, step: -1, weekStartDay: "monday"
        ).map { wizardLocalISOString($0.start) }!
        let dots = CoreWindowPicker.buildNeighborhood(
            timeframe: .monthly,
            windowStart: prev,
            todayWindowStart: monthlyToday,
            boardsByStart: [:],
            weekStartDay: "monday"
        )
        XCTAssertTrue(dots[2].isDisplayed)
        XCTAssertFalse(dots[2].isToday)
        XCTAssertTrue(dots[3].isToday, "+1 from the previous month is today's window")
    }

    // MARK: - Chip suffix

    func test_chipLabelSuffix() {
        let sealed = makeBoard(id: "s", startDate: monthlyToday, sealedAt: "2026-09-01T00:00:00.000")
        XCTAssertEqual(CoreWindowPicker.chipLabelSuffix(board: sealed, isCurrentWindow: false, isPastWindow: true), " · closed")
        XCTAssertEqual(CoreWindowPicker.chipLabelSuffix(board: nil, isCurrentWindow: false, isPastWindow: false), " · next")
        XCTAssertEqual(CoreWindowPicker.chipLabelSuffix(board: nil, isCurrentWindow: false, isPastWindow: true), " · past")
        XCTAssertEqual(CoreWindowPicker.chipLabelSuffix(board: nil, isCurrentWindow: true, isPastWindow: false), "")
        let live = makeBoard(id: "l", startDate: monthlyToday)
        XCTAssertEqual(CoreWindowPicker.chipLabelSuffix(board: live, isCurrentWindow: false, isPastWindow: false), "")
    }

    // MARK: - Tile states

    func test_tileState_sixStateTable() {
        let live = makeBoard(id: "b", startDate: monthlyToday)
        let sealed = makeBoard(id: "s", startDate: monthlyToday, sealedAt: "x")
        let done = makeBoard(id: "d", startDate: monthlyToday, status: "completed")
        let draft = makeBoard(id: "dr", startDate: monthlyToday, status: "draft")

        XCTAssertEqual(CoreWindowPicker.tileState(board: sealed, isCurrent: false, isPast: true, isNext: false), .closed)
        XCTAssertEqual(CoreWindowPicker.tileState(board: done, isCurrent: false, isPast: true, isNext: false), .done)
        XCTAssertEqual(CoreWindowPicker.tileState(board: nil, isCurrent: false, isPast: true, isNext: false), .pastEmpty)
        XCTAssertEqual(CoreWindowPicker.tileState(board: live, isCurrent: true, isPast: false, isNext: false), .current)
        XCTAssertEqual(CoreWindowPicker.tileState(board: nil, isCurrent: true, isPast: false, isNext: false), .current)
        XCTAssertEqual(CoreWindowPicker.tileState(board: nil, isCurrent: false, isPast: false, isNext: true), .nextEmpty)
        XCTAssertEqual(CoreWindowPicker.tileState(board: nil, isCurrent: false, isPast: false, isNext: false), .futureEmpty)
        XCTAssertEqual(CoreWindowPicker.tileState(board: live, isCurrent: false, isPast: false, isNext: false), .inProgress)
        XCTAssertEqual(CoreWindowPicker.tileState(board: draft, isCurrent: true, isPast: false, isNext: false), .draft)
    }

    // MARK: - Pages

    func test_buildPage_monthlyYearGrid() {
        let boards = [monthlyToday: makeBoard(id: "sep", startDate: monthlyToday)]
        let page = CoreWindowPicker.buildPage(
            timeframe: .monthly,
            pageStart: CoreWindowPicker.pageStart(timeframe: .monthly, containing: now),
            boardsByStart: boards,
            now: now,
            weekStartDay: "monday"
        )
        XCTAssertEqual(page.tiles.count, 12)
        XCTAssertEqual(page.title, "2026")
        let current = page.tiles.first(where: \.isCurrent)
        XCTAssertEqual(current?.label, "Sep")
        XCTAssertEqual(current?.state, .current)
        XCTAssertEqual(current?.progressDone, 4)
        XCTAssertEqual(current?.progressTotal, 9)
        XCTAssertEqual(page.tiles[9].state, .nextEmpty, "October is the empty +1 window")
        XCTAssertEqual(page.tiles[10].state, .futureEmpty, "November is further future")
        XCTAssertEqual(page.tiles[0].state, .pastEmpty, "January is a past empty window")
    }

    func test_buildPage_dailyMonthCalendar() {
        let page = CoreWindowPicker.buildPage(
            timeframe: .daily,
            pageStart: CoreWindowPicker.pageStart(timeframe: .daily, containing: now),
            boardsByStart: [:],
            now: now,
            weekStartDay: "monday"
        )
        XCTAssertEqual(page.tiles.count, 30, "September has 30 days")
        XCTAssertEqual(page.title, "September 2026")
        XCTAssertEqual(page.leadingBlanks, 1, "Sep 1 2026 is a Tuesday (Monday start)")
        XCTAssertEqual(page.tiles[0].label, "1")
    }

    func test_buildPage_weeklyQuarter() {
        let page = CoreWindowPicker.buildPage(
            timeframe: .weekly,
            pageStart: CoreWindowPicker.pageStart(timeframe: .weekly, containing: now),
            boardsByStart: [:],
            now: now,
            weekStartDay: "monday"
        )
        XCTAssertEqual(page.title, "Q3 2026")
        XCTAssertTrue((12...14).contains(page.tiles.count))
        for tile in page.tiles {
            XCTAssertTrue(tile.windowStart >= "2026-07-01")
            XCTAssertTrue(tile.windowStart < "2026-10-01")
        }
    }

    func test_buildPage_yearlyDecade() {
        let page = CoreWindowPicker.buildPage(
            timeframe: .yearly,
            pageStart: CoreWindowPicker.pageStart(timeframe: .yearly, containing: now),
            boardsByStart: [:],
            now: now,
            weekStartDay: "monday"
        )
        XCTAssertEqual(page.tiles.count, 10)
        XCTAssertEqual(page.title, "2020 – 2029")
        XCTAssertEqual(page.tiles[0].label, "2020")
    }

    // MARK: - Labels + page stepping

    func test_labels() {
        XCTAssertEqual(CoreWindowPicker.tileLabel(timeframe: .monthly, windowStart: "2026-09-01T00:00:00.000"), "Sep")
        XCTAssertEqual(CoreWindowPicker.tileLabel(timeframe: .yearly, windowStart: "2026-01-01T00:00:00.000"), "2026")
        XCTAssertEqual(CoreWindowPicker.tileLabel(timeframe: .daily, windowStart: "2026-09-05T00:00:00.000"), "5")
        XCTAssertEqual(CoreWindowPicker.tileLabel(timeframe: .weekly, windowStart: "2026-09-14T00:00:00.000"), "Sep 14 – 20")
        XCTAssertEqual(CoreWindowPicker.captionSideLabel(timeframe: .monthly, windowStart: "2026-08-01T00:00:00.000"), "August")
        XCTAssertEqual(CoreWindowPicker.captionSideLabel(timeframe: .daily, windowStart: "2026-09-14T00:00:00.000"), "Sep 14")
        XCTAssertEqual(CoreWindowPicker.captionSideLabel(timeframe: .yearly, windowStart: "2027-01-01T00:00:00.000"), "2027")
    }

    func test_stepPage() {
        let cal = Calendar.current
        let year = CoreWindowPicker.pageStart(timeframe: .monthly, containing: now)
        XCTAssertEqual(cal.component(.year, from: CoreWindowPicker.stepPage(timeframe: .monthly, pageStart: year, step: 1)), 2027)
        let decade = CoreWindowPicker.pageStart(timeframe: .yearly, containing: now)
        XCTAssertEqual(cal.component(.year, from: CoreWindowPicker.stepPage(timeframe: .yearly, pageStart: decade, step: -1)), 2010)
        let month = CoreWindowPicker.pageStart(timeframe: .daily, containing: now)
        XCTAssertEqual(cal.component(.month, from: CoreWindowPicker.stepPage(timeframe: .daily, pageStart: month, step: 1)), 10)
        let quarter = CoreWindowPicker.pageStart(timeframe: .weekly, containing: now)
        XCTAssertEqual(
            CoreWindowPicker.pageTitle(timeframe: .weekly, pageStart: CoreWindowPicker.stepPage(timeframe: .weekly, pageStart: quarter, step: 1)),
            "Q4 2026"
        )
    }
}
