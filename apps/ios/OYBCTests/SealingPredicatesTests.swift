import XCTest
@testable import OYBC

/// Windowed Completion PR C, slice 2/2 — the pure sealing/gating predicates
/// (Helpers/Sealing.swift). Twin coverage of the DB-level SealingTests, but
/// exercised directly against `Board` fixtures with no `AppDatabase` — these
/// are the exact predicates the Boards-tab closing-out banner and
/// `BoardPlayView`'s edit/interaction gating read.
final class SealingPredicatesTests: XCTestCase {

    private let start = "2026-07-01T00:00:00.000Z"
    private let end = "2026-07-02T00:00:00.000Z"
    private let pastEnd = "2026-07-02T12:00:00.000Z" // > end, well inside the 6h daily backstop grace

    private func makeBoard(
        status: BoardStatus = .active,
        timeframe: Timeframe = .daily,
        startDate: String? = nil,
        endDate: String? = nil,
        sealedAt: String? = nil,
        isDeleted: Bool = false
    ) -> Board {
        var dict: [String: Any] = [
            "id": "b1", "userId": "u1", "name": "B", "status": status.rawValue,
            "boardSize": 3, "timeframe": timeframe.rawValue,
            "startDate": startDate ?? start,
            "centerSquareType": "none", "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": isDeleted,
        ]
        if timeframe != .indefinite {
            dict["endDate"] = endDate ?? end
        }
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - isBoardSealable

    func test_isBoardSealable_trueForOrdinaryActiveBoard() {
        XCTAssertTrue(isBoardSealable(makeBoard()))
    }

    func test_isBoardSealable_falseWhenAlreadySealed() {
        XCTAssertFalse(isBoardSealable(makeBoard(sealedAt: pastEnd)))
    }

    func test_isBoardSealable_falseWhenDeleted() {
        XCTAssertFalse(isBoardSealable(makeBoard(isDeleted: true)))
    }

    func test_isBoardSealable_falseForDraft() {
        XCTAssertFalse(isBoardSealable(makeBoard(status: .draft)))
    }

    func test_isBoardSealable_falseForIndefiniteTimeframe() {
        XCTAssertFalse(isBoardSealable(makeBoard(timeframe: .indefinite)))
    }

    func test_isBoardSealable_trueForArchived_orthogonalToSealing() {
        // Archived is a status, orthogonal to sealing — an archived board can
        // still be sealed (docs "Archived boards seal normally").
        XCTAssertTrue(isBoardSealable(makeBoard(status: .archived)))
    }

    // MARK: - isBoardClosingOut

    func test_isBoardClosingOut_trueWhenEndDatePassed() {
        let nowMs = DateFormatting.parseISO(pastEnd)!.timeIntervalSince1970 * 1000
        XCTAssertTrue(isBoardClosingOut(makeBoard(), nowMs: nowMs))
    }

    func test_isBoardClosingOut_falseWhileWindowStillOpen() {
        let inWindowMs = DateFormatting.parseISO("2026-07-01T12:00:00.000Z")!.timeIntervalSince1970 * 1000
        XCTAssertFalse(isBoardClosingOut(makeBoard(), nowMs: inWindowMs))
    }

    func test_isBoardClosingOut_falseWhenAlreadySealed() {
        let nowMs = DateFormatting.parseISO(pastEnd)!.timeIntervalSince1970 * 1000
        XCTAssertFalse(isBoardClosingOut(makeBoard(sealedAt: pastEnd), nowMs: nowMs))
    }

    func test_isBoardClosingOut_falseForDraft() {
        let nowMs = DateFormatting.parseISO(pastEnd)!.timeIntervalSince1970 * 1000
        XCTAssertFalse(isBoardClosingOut(makeBoard(status: .draft), nowMs: nowMs))
    }

    func test_isBoardClosingOut_falseForIndefinite() {
        let nowMs = DateFormatting.parseISO(pastEnd)!.timeIntervalSince1970 * 1000
        XCTAssertFalse(isBoardClosingOut(makeBoard(timeframe: .indefinite), nowMs: nowMs))
    }

    // MARK: - isBoardPlayLocked (BoardPlayView's play/edit gating predicate)

    func test_isBoardPlayLocked_falseForLiveActiveBoard() {
        let board = makeBoard(
            startDate: "2026-07-01T00:00:00.000Z",
            endDate: "2026-07-02T00:00:00.000Z"
        )
        XCTAssertFalse(isBoardPlayLocked(board))
    }

    func test_isBoardPlayLocked_trueWhenSealed_evenIfWindowStillOpen() {
        // A sealed board is never interactable, regardless of expiry.
        let board = makeBoard(startDate: "2026-07-01T00:00:00.000Z", endDate: "2099-01-01T00:00:00.000Z", sealedAt: start)
        XCTAssertTrue(isBoardPlayLocked(board))
    }

    func test_isBoardPlayLocked_falseWhenExpiredButNotSealed() {
        // Sealing REPLACES the old expiry lock (docs §Lifecycle: an
        // expired-but-unsealed board is "still fully live" — the closing-out
        // banner's Log action opens it to log late activity; the backstop
        // bounds the overtime and then seals+locks it).
        let board = makeBoard(startDate: "2020-01-01T00:00:00.000Z", endDate: "2020-01-02T00:00:00.000Z")
        XCTAssertFalse(isBoardPlayLocked(board))
    }

    func test_isBoardPlayLocked_falseForIndefiniteBoard_neverExpiresNeverSeals() {
        XCTAssertFalse(isBoardPlayLocked(makeBoard(timeframe: .indefinite)))
    }
}
