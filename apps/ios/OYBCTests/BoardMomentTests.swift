import XCTest
@testable import OYBC

/// The moment's smaller pure pieces: the flash payload ladder, the beat
/// helpers on a hand-built replay, `totalLineCount`, `streakUnitLabel`.
final class BoardMomentTests: XCTestCase {

    // MARK: totalLineCount / streakUnitLabel

    func test_totalLineCount() {
        XCTAssertEqual(BingoDetection.totalLineCount(gridSize: 3), 8)
        XCTAssertEqual(BingoDetection.totalLineCount(gridSize: 4), 10)
        XCTAssertEqual(BingoDetection.totalLineCount(gridSize: 5), 12)
    }

    func test_totalLineCount_matchesDetectableLines() {
        for n in 3...5 {
            let all = BingoDetection.detectBingos(completionGrid: Array(repeating: true, count: n * n), gridSize: n)
            XCTAssertEqual(all.completedLines.count, BingoDetection.totalLineCount(gridSize: n))
        }
    }

    func test_streakUnitLabel() {
        XCTAssertEqual(streakUnitLabel(.daily), "DAY")
        XCTAssertEqual(streakUnitLabel(.weekly), "WEEK")
        XCTAssertEqual(streakUnitLabel(.monthly), "MONTH")
        XCTAssertEqual(streakUnitLabel(.yearly), "YEAR")
        XCTAssertEqual(streakUnitLabel(.custom), "")
        XCTAssertEqual(streakUnitLabel(.indefinite), "")
    }

    // MARK: Flash payload ladder

    func test_flash_newLine_isOneBingoTrigger() {
        let out = BoardFlashOutcome.resolve(wasReactivated: false, lost: [], gained: ["row_1"], didGreenlog: false)
        XCTAssertEqual(out.moment, MomentTrigger(kind: .bingo, newLineIds: ["row_1"]))
        XCTAssertEqual(out.message, "Bingo! (row_1)")
    }

    func test_flash_twoLinesAtOnce_isOneTrigger() {
        let out = BoardFlashOutcome.resolve(wasReactivated: false, lost: [], gained: ["col_2", "row_0"], didGreenlog: false)
        XCTAssertEqual(out.moment, MomentTrigger(kind: .bingo, newLineIds: ["col_2", "row_0"]))
    }

    func test_flash_greenlogBeatsBingo() {
        let out = BoardFlashOutcome.resolve(wasReactivated: false, lost: [], gained: ["row_2", "diag_main"], didGreenlog: true)
        XCTAssertEqual(out.moment?.kind, .greenlog)
        XCTAssertEqual(out.moment?.newLineIds, ["diag_main", "row_2"])
        XCTAssertEqual(out.message, "GREENLOG!")
    }

    func test_flash_lostBingoAndReactivationOutrankAndCarryNoMoment() {
        let lost = BoardFlashOutcome.resolve(wasReactivated: false, lost: ["row_0"], gained: ["col_1"], didGreenlog: true)
        XCTAssertNil(lost.moment)
        XCTAssertEqual(lost.message, "Bingo lost: row_0")
        let reactivated = BoardFlashOutcome.resolve(wasReactivated: true, lost: ["row_0"], gained: [], didGreenlog: false)
        XCTAssertNil(reactivated.moment)
        XCTAssertEqual(reactivated.message, "Board reactivated — no longer complete")
    }

    func test_flash_nothingChanged() {
        XCTAssertEqual(BoardFlashOutcome.resolve(wasReactivated: false, lost: [], gained: [], didGreenlog: false), .none)
    }

    // MARK: Beat helpers / frames on a hand-built replay

    private func replay3x3() -> BoardMomentReplay {
        BoardMomentReplay(
            order: [
                MomentOrderEntry(boardTaskId: "a", idx: 8, completedAt: nil),
                MomentOrderEntry(boardTaskId: "b", idx: 0, completedAt: nil),
                MomentOrderEntry(boardTaskId: "c", idx: 1, completedAt: nil),
            ],
            freeIdx: 4, lineClosureBeat: ["diag_main": 3], completedTasks: 4, totalTasks: 9, size: 3
        )
    }

    func test_cellVisual_emptyBoardAtBeatZero() {
        let r = replay3x3()
        for idx in 0..<9 {
            XCTAssertEqual(momentCellVisual(idx: idx, beat: 0, replay: r, kind: .bingo), MomentCellVisual(landed: false, green: false, popToken: nil))
        }
    }

    func test_cellVisual_landsThenFlipsGreen_freeIncluded() {
        let r = replay3x3()
        XCTAssertEqual(momentCellVisual(idx: 8, beat: 1, replay: r, kind: .bingo), MomentCellVisual(landed: true, green: false, popToken: 1))
        // diag_main (0, 4, 8) closes at beat 3: FREE (4) flips green without ever landing.
        XCTAssertEqual(momentCellVisual(idx: 4, beat: 2, replay: r, kind: .bingo), MomentCellVisual(landed: false, green: false, popToken: nil))
        XCTAssertEqual(momentCellVisual(idx: 4, beat: 3, replay: r, kind: .bingo), MomentCellVisual(landed: false, green: true, popToken: 3))
        XCTAssertEqual(momentCellVisual(idx: 8, beat: 3, replay: r, kind: .bingo), MomentCellVisual(landed: true, green: true, popToken: 3))
        // Cell 1 landed at beat 3 but is on no closed line.
        XCTAssertEqual(momentCellVisual(idx: 1, beat: 3, replay: r, kind: .bingo), MomentCellVisual(landed: true, green: false, popToken: 3))
    }

    func test_cellVisual_greenlogSweepIgnoresLines() {
        let r = replay3x3()
        // Sweep reaches (r, c) at order.count + 1 + r + c = 4 + r + c.
        XCTAssertFalse(momentCellVisual(idx: 0, beat: 3, replay: r, kind: .greenlog).green)
        XCTAssertTrue(momentCellVisual(idx: 0, beat: 4, replay: r, kind: .greenlog).green)
        XCTAssertFalse(momentCellVisual(idx: 4, beat: 5, replay: r, kind: .greenlog).green)
        XCTAssertTrue(momentCellVisual(idx: 4, beat: 6, replay: r, kind: .greenlog).green)
        XCTAssertTrue(momentCellVisual(idx: 8, beat: momentFinalBeat(r, kind: .greenlog), replay: r, kind: .greenlog).green)
    }

    func test_counterAndFinalBeat() {
        let r = replay3x3()
        XCTAssertEqual(momentCounterAt(0, replay: r), 1) // FREE present from beat 0
        XCTAssertEqual(momentCounterAt(2, replay: r), 3)
        XCTAssertEqual(momentCounterAt(99, replay: r), 4) // ends at completedTasks
        XCTAssertEqual(momentFinalBeat(r, kind: .bingo), 3)
        XCTAssertEqual(momentFinalBeat(r, kind: .greenlog), 3 + 1 + 4)
    }

    func test_sortOrder_datedFirstThenUndatedByIdx() {
        let sorted = sortMomentOrder([
            MomentOrderEntry(boardTaskId: "n7", idx: 7, completedAt: nil),
            MomentOrderEntry(boardTaskId: "late", idx: 1, completedAt: "2026-10-02T12:00:00.000Z"),
            MomentOrderEntry(boardTaskId: "n2", idx: 2, completedAt: "not a date"),
            MomentOrderEntry(boardTaskId: "early", idx: 5, completedAt: "2026-10-02T08:00:00.000Z"),
            MomentOrderEntry(boardTaskId: "tieB", idx: 6, completedAt: "2026-10-02T08:00:00.000Z"),
        ])
        XCTAssertEqual(sorted.map(\.boardTaskId), ["early", "tieB", "late", "n2", "n7"])
    }
}
