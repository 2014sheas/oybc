import XCTest
@testable import OYBC

/// Board Edit redesign slice 2 (T1) — the pure `BoardDetailsDraft` (D12 date
/// semantics + count/patch agreement + validation). Same case table as web
/// `boardDetailsPatch.test.ts`.
final class BoardDetailsDraftTests: XCTestCase {

    private let cal = Calendar.current

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func makeBoard(
        timeframe: Timeframe,
        startDate: String = "2026-09-01T00:00:00.000",
        endDate: String? = "2026-09-30T23:59:59.999",
        center: CenterSquareType = .free,
        centerTaskId: String? = nil,
        name: String = "Board"
    ) -> Board {
        var dict: [String: Any] = [
            "id": "b1", "userId": "u1", "name": name, "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": timeframe.rawValue, "startDate": startDate,
            "centerSquareType": center.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": startDate, "updatedAt": startDate, "version": 1, "isDeleted": false,
        ]
        if let endDate { dict["endDate"] = endDate }
        if let centerTaskId { dict["centerTaskId"] = centerTaskId }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - Seeding

    func test_seed_parsesFullISOBoardDates_notToday() {
        let d = BoardDetailsDraft(board: makeBoard(timeframe: .custom))
        XCTAssertEqual(cal.startOfDay(for: d.startDate), day(2026, 9, 1))
        XCTAssertEqual(cal.startOfDay(for: d.endDate), day(2026, 9, 30))
        XCTAssertFalse(d.isDirty)
        XCTAssertNil(d.patch())
    }

    // MARK: - D12 date semantics

    func test_ongoingStartEdit_writesStartOnly() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .indefinite, endDate: nil))
        d.startDate = day(2026, 8, 15, hour: 13)
        XCTAssertEqual(d.editCount, 1)
        XCTAssertEqual(d.patch(), AppDatabase.UpdateActiveBoardPatch(startDate: "2026-08-15T00:00:00.000"))
    }

    func test_ongoingEndEdit_isIgnored() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .indefinite, endDate: nil))
        d.endDate = day(2027, 1, 1)
        XCTAssertEqual(d.editCount, 0)
        XCTAssertNil(d.patch())
    }

    func test_customToOngoing_keepsStart_clearsEnd() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .custom))
        d.timeframe = .indefinite
        XCTAssertEqual(d.editCount, 1)
        XCTAssertEqual(d.patch(), AppDatabase.UpdateActiveBoardPatch(
            timeframe: .indefinite, startDate: "2026-09-01T00:00:00.000", clearEndDate: true))
    }

    func test_customToOngoing_withEditedStart_keepsEditedStart() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .custom))
        d.timeframe = .indefinite
        d.startDate = day(2026, 8, 20)
        XCTAssertEqual(d.editCount, 1)
        XCTAssertEqual(d.patch(), AppDatabase.UpdateActiveBoardPatch(
            timeframe: .indefinite, startDate: "2026-08-20T00:00:00.000", clearEndDate: true))
    }

    func test_ongoingToCustom_writesStartAndEnd() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .indefinite, endDate: nil))
        d.timeframe = .custom
        d.endDate = day(2026, 10, 10)
        XCTAssertEqual(d.editCount, 1)
        XCTAssertEqual(d.patch(), AppDatabase.UpdateActiveBoardPatch(
            timeframe: .custom, startDate: "2026-09-01T00:00:00.000", endDate: "2026-10-10T23:59:59.999"))
    }

    func test_customDateEdit_writesBothDates() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .custom))
        d.endDate = day(2026, 10, 5)
        XCTAssertEqual(d.editCount, 1)
        XCTAssertEqual(d.patch(), AppDatabase.UpdateActiveBoardPatch(
            startDate: "2026-09-01T00:00:00.000", endDate: "2026-10-05T23:59:59.999"))
    }

    func test_subToleranceDateJitter_isNotAnEdit() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .custom))
        d.startDate = d.startDate.addingTimeInterval(30)
        XCTAssertEqual(d.editCount, 0)
        XCTAssertNil(d.patch())
    }

    func test_calendarTimeframe_neitherDatesNorTimeframeWrite() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .monthly))
        d.startDate = day(2026, 8, 1)
        d.timeframe = .weekly
        XCTAssertEqual(d.effectiveTimeframe, .monthly)
        XCTAssertEqual(d.editCount, 0)
        XCTAssertNil(d.patch())
    }

    func test_metadataOnly_omitsDates() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .indefinite, endDate: nil))
        d.name = "  Renamed  "
        XCTAssertEqual(d.patch(), AppDatabase.UpdateActiveBoardPatch(name: "Renamed"))
    }

    // MARK: - Count ⇄ patch agreement

    func test_countMatchesPatchShape() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .custom))
        d.name = "New"
        d.endDate = day(2026, 10, 8)
        XCTAssertEqual(d.editCount, 2)
        let p = d.patch()
        XCTAssertEqual(p?.name, "New")
        XCTAssertNil(p?.centerSquareType, "Board details never writes the center (slice 3, D6)")
        XCTAssertNotNil(p?.endDate)

        // Whitespace-only rename counts nothing and writes nothing.
        var w = BoardDetailsDraft(board: makeBoard(timeframe: .custom))
        w.name = "Board   "
        XCTAssertEqual(w.editCount, 0)
        XCTAssertNil(w.patch())
    }

    // MARK: - Validation

    func test_validation_nameRequired() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .custom))
        d.name = "   "
        XCTAssertEqual(d.validationError(), "Board name is required.")
    }

    func test_validation_customEndBeforeStart() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .custom))
        d.endDate = day(2026, 8, 1)
        XCTAssertEqual(d.validationError(),
                       "End date must be on or after the start date.")
        d.endDate = day(2026, 9, 1, hour: 5)   // same day is fine
        XCTAssertNil(d.validationError())
    }

    /// Board Edit slice 3 (D6): the center group is gone — the center now
    /// changes only in the squares editor, so a legacy CHOSEN board saves
    /// name/date edits without any center validation and the patch never
    /// carries a center field.
    func test_legacyChosenBoard_detailsSaveNeverTouchesCenter() {
        var d = BoardDetailsDraft(board: makeBoard(timeframe: .custom, center: .chosen, centerTaskId: nil))
        XCTAssertEqual(d.editCount, 0)
        d.name = "Renamed"
        XCTAssertNil(d.validationError())
        XCTAssertEqual(d.editCount, 1)
        XCTAssertEqual(d.patch(), AppDatabase.UpdateActiveBoardPatch(name: "Renamed"))
    }

    // MARK: - Read-only calendar window (slice 2 self-review)

    /// A monthly board from a PAST month shows ITS window, not the month
    /// containing `now` (the sheet used to render today's window).
    func test_readOnlyWindow_prefersStoredWindow_overToday() {
        let stored = (start: day(2020, 2, 1), end: day(2020, 2, 29, hour: 23))
        let now = day(2026, 9, 26)
        let w = BoardSetupFormView.readOnlyWindow(
            timeframe: .monthly, storedWindow: stored, weekStartDay: "monday", now: now
        )
        XCTAssertEqual(w?.start, stored.start)
        XCTAssertEqual(w?.end, stored.end)
    }

    func test_readOnlyWindow_withoutStoredWindow_fallsBackToWindowContainingNow() {
        let now = day(2026, 9, 26)
        let w = BoardSetupFormView.readOnlyWindow(
            timeframe: .monthly, storedWindow: nil, weekStartDay: "monday", now: now
        )
        XCTAssertEqual(w?.start, day(2026, 9, 1))
    }

    func test_readOnlyWindow_customAndOngoing_haveNoNote() {
        let stored = (start: day(2020, 2, 1), end: day(2020, 2, 29))
        for tf in [Timeframe.custom, .indefinite] {
            XCTAssertNil(BoardSetupFormView.readOnlyWindow(
                timeframe: tf, storedWindow: stored, weekStartDay: "monday", now: day(2026, 9, 26)
            ))
        }
    }
}
