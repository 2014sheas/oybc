import XCTest
@testable import OYBC

/// Twin of `packages/shared/tests/algorithms/boardDisplayName.test.ts`.
/// Keep the two suites in lockstep — they pin the same cross-platform
/// contract for healing board names frozen as "Today".
final class BoardDisplayNameTests: XCTestCase {

    /// A board for the given local-ISO start, named exactly as stored.
    ///
    /// Built through JSON decode (the same path GRDB uses) so the fixture
    /// can't drift from the real decoding behaviour.
    private func makeBoard(
        name: String,
        startDate: String,
        timeframe: Timeframe = .daily,
        isCore: Bool = true
    ) -> Board {
        let dict: [String: Any] = [
            "id": "b-\(startDate)-\(name)",
            "userId": "u1",
            "name": name,
            "status": BoardStatus.active.rawValue,
            "boardSize": 3,
            "timeframe": timeframe.rawValue,
            "startDate": startDate,
            "endDate": startDate,
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "isCore": isCore,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": startDate,
            "updatedAt": startDate,
            "version": 1,
            "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    /// A daily CORE board — the shape that actually froze "Today".
    private func coreBoard(
        name: String,
        startDate: String,
        timeframe: Timeframe = .daily
    ) -> Board {
        makeBoard(name: name, startDate: startDate, timeframe: timeframe, isCore: true)
    }

    // MARK: - Heals the frozen "Today"

    func testReplacesBareTodayWithTheBoardsOwnDate() {
        let healed = coreBoard(name: "Today", startDate: "2026-03-15T00:00:00.000").displayName
        // Asserting the EXACT string (not merely "!= Today") — a helper that
        // returned "" or the timeframe name would also stop saying "Today".
        XCTAssertEqual(healed, "Mar 15, 2026")
    }

    func testTwoBoardsFrozenAsTodayGetDifferentNames() {
        // This is the actual user-visible bug: a list of daily core boards
        // that all read "Today" and cannot be told apart when searching.
        let a = coreBoard(name: "Today", startDate: "2026-03-15T00:00:00.000").displayName
        let b = coreBoard(name: "Today", startDate: "2026-03-16T00:00:00.000").displayName
        XCTAssertNotEqual(a, b)
        XCTAssertEqual([a, b], ["Mar 15, 2026", "Mar 16, 2026"])
    }

    func testHealsOnlyTheWindowHalfOfASpawnedName() {
        let healed = coreBoard(name: "Leg Day — Today", startDate: "2026-03-15T00:00:00.000").displayName
        XCTAssertEqual(healed, "Leg Day — Mar 15, 2026")
    }

    func testKeepsAnEmDashBelongingToTheTemplateName() {
        // Only the trailing " — Today" is the composed half; an em-dash
        // earlier in the user's own template name must survive.
        let healed = coreBoard(name: "Push — Pull — Today", startDate: "2026-03-15T00:00:00.000").displayName
        XCTAssertEqual(healed, "Push — Pull — Mar 15, 2026")
    }

    // MARK: - Leaves everything else alone

    func testReturnsAUserRenamedCoreBoardVerbatim() {
        XCTAssertEqual(
            coreBoard(name: "My Big Day", startDate: "2026-03-15T00:00:00.000").displayName,
            "My Big Day"
        )
    }

    func testDoesNotHealANonCoreBoardNamedToday() {
        // A one-off board the user typed "Today" into is authored data.
        let oneOff = makeBoard(name: "Today", startDate: "2026-03-15T00:00:00.000", isCore: false)
        XCTAssertEqual(oneOff.displayName, "Today")
    }

    func testDoesNotTouchANameMerelyContainingTheWordToday() {
        XCTAssertEqual(
            coreBoard(name: "Today I conquer", startDate: "2026-03-15T00:00:00.000").displayName,
            "Today I conquer"
        )
    }

    func testIsCaseSensitive() {
        XCTAssertEqual(
            coreBoard(name: "today", startDate: "2026-03-15T00:00:00.000").displayName,
            "today"
        )
    }

    func testPassesThroughAlreadyAbsoluteNames() {
        // These timeframes never had a relative branch, so were never broken.
        XCTAssertEqual(
            coreBoard(name: "September 2026", startDate: "2026-09-01T00:00:00.000", timeframe: .monthly).displayName,
            "September 2026"
        )
        XCTAssertEqual(
            coreBoard(name: "2026", startDate: "2026-01-01T00:00:00.000", timeframe: .yearly).displayName,
            "2026"
        )
    }

    // MARK: - Identity preservation

    func testHealingDisplayNameReturnsSelfWhenNothingToHeal() {
        let board = coreBoard(name: "My Big Day", startDate: "2026-03-15T00:00:00.000")
        XCTAssertEqual(board.healingDisplayName().name, board.name)
    }

    func testHealingDisplayNameRewritesOnlyTheName() {
        let board = coreBoard(name: "Today", startDate: "2026-03-15T00:00:00.000")
        let healed = board.healingDisplayName()
        XCTAssertEqual(healed.name, "Mar 15, 2026")
        // Everything else must survive untouched — this copy is what the
        // fetchers hand to the UI.
        XCTAssertEqual(healed.id, board.id)
        XCTAssertEqual(healed.version, board.version)
        XCTAssertEqual(healed.startDate, board.startDate)
        XCTAssertEqual(healed.isCore, board.isCore)
    }

    // MARK: - formatWindowLabel vs formatTimeframeLabel

    func testFormatWindowLabelNeverSaysTodayEvenForTheCurrentWindow() {
        // This is what makes it safe to persist. If this regresses, the mint
        // path starts freezing "Today" into names all over again.
        let today = Date()
        let label = formatWindowLabel(timeframe: .daily, startDate: today)
        XCTAssertNotEqual(label, "Today")

        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MMM d, yyyy"
        XCTAssertEqual(label, f.string(from: today))
    }

    func testFormatTimeframeLabelStillSaysTodayForLiveChrome() {
        // The relative label is correct and wanted at render time — the
        // window chip and pager caption rely on it.
        XCTAssertEqual(formatTimeframeLabel(timeframe: .daily, startDate: Date()), "Today")
    }

    func testFormatTimeframeLabelHonoursAPinnedNow() {
        // Pinning a far-past instant proves the parameter drives the answer:
        // a 2026 window is not "Today" when now is 2020.
        let window = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 15))!
        let longBefore = Calendar.current.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        XCTAssertEqual(
            formatTimeframeLabel(timeframe: .daily, startDate: window, now: longBefore),
            "Mar 15, 2026"
        )
    }
}
