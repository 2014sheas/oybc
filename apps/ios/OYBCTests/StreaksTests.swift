import XCTest
@testable import OYBC

/// Unit tests for `computeStreak` / `computeAllStreaks` — parity with
/// `packages/shared/tests/algorithms/streaks.test.ts`. `now`-injected for
/// determinism. Mirrors the `RecurringBoardsTests` fixture style.
final class StreaksTests: XCTestCase {

    // Mon Jun 15 2026, midday — a Monday, so monday-start weekly windows align.
    private func now() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 15; c.hour = 12
        c.calendar = Calendar.current
        c.timeZone = TimeZone.current
        return Calendar.current.date(from: c)!
    }

    /// Builds a core Board for a window (decoded via Codable, the path remote
    /// payloads take — `Board` has no memberwise init).
    private func coreBoard(
        timeframe: Timeframe,
        window: (start: Date, end: Date),
        status: BoardStatus = .active,
        linesCompleted: Int = 0,
        isCore: Bool = true,
        isDeleted: Bool = false
    ) -> Board {
        let dict: [String: Any] = [
            "id": "b-\(timeframe.rawValue)-\(wizardLocalISOString(window.start))",
            "userId": "u1",
            "name": "core",
            "status": status.rawValue,
            "boardSize": 5,
            "timeframe": timeframe.rawValue,
            "startDate": wizardLocalISOString(window.start),
            "endDate": wizardLocalISOString(window.end),
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": true,
            "totalTasks": 25,
            "completedTasks": 0,
            "linesCompleted": linesCompleted,
            "createdAt": "2026-01-01T00:00:00.000",
            "updatedAt": "2026-01-01T00:00:00.000",
            "version": 1,
            "isDeleted": isDeleted,
            "isCore": isCore,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    /// Windows [current, prev, prev-1, …] going back `count` steps.
    private func windowsBack(_ timeframe: Timeframe, _ ref: Date, _ count: Int) -> [(start: Date, end: Date)] {
        var out: [(start: Date, end: Date)] = []
        guard var w = computeTimeframeBoundaries(timeframe: timeframe, referenceDate: ref, weekStartDay: "monday") else { return out }
        out.append(w)
        for _ in 1..<count {
            guard let prev = stepCoreBoardWindow(
                timeframe: timeframe, fromStartIso: wizardLocalISOString(w.start), step: -1, weekStartDay: "monday"
            ) else { break }
            w = prev
            out.append(w)
        }
        return out
    }

    private func streak(_ tf: Timeframe, _ c: AchievementTrigger, _ boards: [Board]) -> Int {
        computeStreak(timeframe: tf, criterion: c, boards: boards, weekStartDay: "monday", now: now())
    }

    // greenlog = full board; bingoOnly = a line but not complete.
    private func greenlog(_ tf: Timeframe, _ w: (start: Date, end: Date)) -> Board {
        coreBoard(timeframe: tf, window: w, status: .completed, linesCompleted: 8)
    }
    private func bingoOnly(_ tf: Timeframe, _ w: (start: Date, end: Date)) -> Board {
        coreBoard(timeframe: tf, window: w, status: .active, linesCompleted: 2)
    }

    // MARK: - Tests

    func testNoCoreBoardsIsZero() {
        XCTAssertEqual(streak(.daily, .greenlog, []), 0)
        XCTAssertEqual(streak(.daily, .bingo, []), 0)
    }

    func testCustomIsZero() {
        let w = windowsBack(.daily, now(), 1)
        XCTAssertEqual(streak(.custom, .greenlog, [greenlog(.daily, w[0])]), 0)
    }

    func testIndefiniteIsZero() {
        // `.indefinite` boards have no window cadence — same guard as `.custom`.
        // (Boards can't actually be core+.indefinite in practice, but the guard
        // must be explicit rather than incidentally true via a nil boundary.)
        let w = windowsBack(.daily, now(), 1)
        XCTAssertEqual(streak(.indefinite, .greenlog, [greenlog(.daily, w[0])]), 0)
        XCTAssertEqual(streak(.indefinite, .bingo, [greenlog(.daily, w[0])]), 0)
        XCTAssertEqual(
            computeLongestStreak(timeframe: .indefinite, boards: [greenlog(.daily, w[0])], weekStartDay: "monday", now: now()),
            0
        )
    }

    func testCountsConsecutiveUntilFirstMiss() {
        let w = windowsBack(.daily, now(), 5)
        let boards = [greenlog(.daily, w[0]), greenlog(.daily, w[1]), greenlog(.daily, w[2])]
        XCTAssertEqual(streak(.daily, .greenlog, boards), 3)
    }

    func testCurrentWindowGraceWhenNotAchieved() {
        let w = windowsBack(.daily, now(), 5)
        let boards = [
            coreBoard(timeframe: .daily, window: w[0], status: .active),
            greenlog(.daily, w[1]),
            greenlog(.daily, w[2]),
        ]
        XCTAssertEqual(streak(.daily, .greenlog, boards), 2)
    }

    func testCurrentWindowGraceWhenMissing() {
        let w = windowsBack(.daily, now(), 5)
        let boards = [greenlog(.daily, w[1]), greenlog(.daily, w[2])]
        XCTAssertEqual(streak(.daily, .greenlog, boards), 2)
    }

    func testClosedWindowMissingBreaks() {
        let w = windowsBack(.daily, now(), 5)
        // w0 greenlog, w1 MISSING, w2 greenlog → only w0 counts.
        let boards = [greenlog(.daily, w[0]), greenlog(.daily, w[2])]
        XCTAssertEqual(streak(.daily, .greenlog, boards), 1)
    }

    func testBingoVsGreenlogCriteria() {
        let w = windowsBack(.daily, now(), 4)
        let boards = [bingoOnly(.daily, w[0]), bingoOnly(.daily, w[1])]
        XCTAssertEqual(streak(.daily, .bingo, boards), 2)
        XCTAssertEqual(streak(.daily, .greenlog, boards), 0)
    }

    func testIgnoresNonCoreBoards() {
        let w = windowsBack(.daily, now(), 3)
        let boards = [
            coreBoard(timeframe: .daily, window: w[0], status: .completed, linesCompleted: 8, isCore: false),
            coreBoard(timeframe: .daily, window: w[1], status: .completed, linesCompleted: 8, isCore: false),
        ]
        XCTAssertEqual(streak(.daily, .greenlog, boards), 0)
    }

    func testIgnoresDeletedBoards() {
        let w = windowsBack(.daily, now(), 3)
        let boards = [coreBoard(timeframe: .daily, window: w[0], status: .completed, linesCompleted: 8, isDeleted: true)]
        XCTAssertEqual(streak(.daily, .greenlog, boards), 0)
    }

    func testReversibilityDropsStreak() {
        let w = windowsBack(.daily, now(), 4)
        let boards = [
            coreBoard(timeframe: .daily, window: w[0], status: .active), // un-completed
            greenlog(.daily, w[1]),
            greenlog(.daily, w[2]),
        ]
        XCTAssertEqual(streak(.daily, .greenlog, boards), 2)
    }

    func testWeeklyStreak() {
        let w = windowsBack(.weekly, now(), 4)
        let boards = [greenlog(.weekly, w[0]), greenlog(.weekly, w[1])]
        XCTAssertEqual(streak(.weekly, .greenlog, boards), 2)
    }

    func testComputeAllStreaks() {
        let dw = computeTimeframeBoundaries(timeframe: .daily, referenceDate: now(), weekStartDay: "monday")!
        let all = computeAllStreaks(boards: [greenlog(.daily, dw)], weekStartDay: "monday", now: now())
        XCTAssertEqual(all[.daily], StreakPair(bingo: 1, greenlog: 1))
        XCTAssertEqual(all[.weekly], StreakPair(bingo: 0, greenlog: 0))
        XCTAssertEqual(all[.monthly], StreakPair(bingo: 0, greenlog: 0))
        XCTAssertEqual(all[.yearly], StreakPair(bingo: 0, greenlog: 0))
    }
}
