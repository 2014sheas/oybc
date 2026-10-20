import XCTest
@testable import OYBC

/// The moment's smaller pure pieces: the flash payload ladder, the beat
/// helpers on a hand-built replay, `totalLineCount`, `streakUnitLabel`.
final class BoardMomentTests: XCTestCase {

    // MARK: replayMomentKind (the Bingos card's replay)

    func test_replayMomentKind() {
        func k(_ s: BoardStatus, _ done: Int, _ lines: Int, total: Int = 9) -> MomentTrigger.Kind? {
            replayMomentKind(status: s, completedTasks: done, totalTasks: total, linesCompleted: lines)
        }
        XCTAssertEqual(k(.completed, 9, 8), .greenlog)
        XCTAssertEqual(k(.archived, 9, 8), .greenlog) // archived keeps counts, not status
        XCTAssertEqual(k(.active, 4, 1), .bingo)
        XCTAssertEqual(k(.archived, 7, 3), .bingo)
        XCTAssertNil(k(.active, 2, 0))
        XCTAssertNil(k(.draft, 0, 0, total: 0))
    }

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
        XCTAssertEqual(out.message, "Greenlog!")
    }

    func test_flash_lostBingoAndReactivationOutrankAndCarryNoMoment() {
        let lost = BoardFlashOutcome.resolve(wasReactivated: false, lost: ["row_0"], gained: ["col_1"], didGreenlog: true)
        XCTAssertNil(lost.moment)
        XCTAssertEqual(lost.message, "Bingo lost: row_0")
        let reactivated = BoardFlashOutcome.resolve(wasReactivated: true, lost: ["row_0"], gained: [], didGreenlog: false)
        XCTAssertNil(reactivated.moment)
        XCTAssertEqual(reactivated.message, "No longer complete")
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

    // MARK: resolve(before:after:allowGains:)

    private func board(status: BoardStatus = .active, lines: [String] = [], completed: Int = 0, size: Int = 3, id: String = "b") -> Board {
        func json<T: Encodable>(_ v: T) -> String { String(data: try! JSONEncoder().encode(v), encoding: .utf8)! }
        let dict: [String: Any] = [
            "id": id, "userId": "u", "name": id, "status": status.rawValue, "boardSize": size,
            "timeframe": Timeframe.custom.rawValue, "startDate": "2026-10-01T00:00:00.000Z",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": completed, "linesCompleted": lines.count,
            "completedLineIds": json(lines),
            "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
            "version": 1, "isDeleted": false,
        ]
        return try! JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    func test_resolveBeforeAfter_newLine() {
        let out = BoardFlashOutcome.resolve(before: board(), after: board(lines: ["row_0"], completed: 3))
        XCTAssertEqual(out.moment, MomentTrigger(kind: .bingo, newLineIds: ["row_0"]))
    }

    func test_resolveBeforeAfter_activeToCompletedWithAllSquares_isGreenlog() {
        let out = BoardFlashOutcome.resolve(
            before: board(lines: ["row_0"], completed: 8),
            after: board(status: .completed, lines: ["row_0", "row_1"], completed: 9)
        )
        XCTAssertEqual(out.moment, MomentTrigger(kind: .greenlog, newLineIds: ["row_1"]))
    }

    func test_resolveBeforeAfter_allowGainsFalse_neverOpensAMoment() {
        let out = BoardFlashOutcome.resolve(
            before: board(), after: board(status: .completed, lines: ["row_0"], completed: 9), allowGains: false
        )
        XCTAssertNil(out.moment)
        XCTAssertNil(out.message)
        let lost = BoardFlashOutcome.resolve(before: board(lines: ["row_0"]), after: board(), allowGains: false)
        XCTAssertEqual(lost.message, "Bingo lost: row_0")
    }

    func test_resolveBeforeAfter_nilBoards() {
        XCTAssertEqual(BoardFlashOutcome.resolve(before: nil, after: board()), .none)
    }

    // MARK: resolve(cascade:)

    private func cascade(wasReactivated: Bool = false, auto: Bool = false, new: [String] = [], lost: [String] = []) -> AppDatabase.CascadeBoardResult {
        AppDatabase.CascadeBoardResult(
            update: DerivationPass.BoardStatsUpdate(
                boardId: "b", completedTasks: 0, linesCompleted: 0, completedLineIds: [], newBingos: new, lostBingos: lost
            ),
            wasReactivated: wasReactivated, isGreenlogNow: auto, didAutoComplete: auto
        )
    }

    func test_resolveCascade() {
        XCTAssertEqual(BoardFlashOutcome.resolve(cascade: nil), .none)
        XCTAssertEqual(BoardFlashOutcome.resolve(cascade: cascade(new: ["col_1"])).moment, MomentTrigger(kind: .bingo, newLineIds: ["col_1"]))
        XCTAssertEqual(BoardFlashOutcome.resolve(cascade: cascade(auto: true, new: ["col_1"])).moment?.kind, .greenlog)
        XCTAssertNil(BoardFlashOutcome.resolve(cascade: cascade(wasReactivated: true)).moment)
        XCTAssertNil(BoardFlashOutcome.resolve(cascade: cascade(new: ["col_1"], lost: ["row_0"])).moment)
    }

    // MARK: Gate

    func test_gate_staleViewModelWaits_appliedOpens_timeoutOpensAnyway() {
        let trigger = MomentTrigger(kind: .bingo, newLineIds: ["row_1"])
        let stale = board(lines: [])
        let fresh = board(lines: ["row_1"])
        // Stale: reload has not applied (count unchanged) → not ready, waits past the minimum…
        let notReady = MomentGate.isReady(trigger, boardId: "b", board: stale, applyCount: 4, applyCountAtTrigger: 4)
        XCTAssertFalse(notReady)
        XCTAssertFalse(MomentGate.shouldOpen(elapsed: 0.6, ready: notReady))
        // …applied but the board lacks the line → still waiting.
        XCTAssertFalse(MomentGate.isReady(trigger, boardId: "b", board: stale, applyCount: 5, applyCountAtTrigger: 4))
        // Applied and the board shows the line → opens, but never before the pop minimum.
        let ready = MomentGate.isReady(trigger, boardId: "b", board: fresh, applyCount: 5, applyCountAtTrigger: 4)
        XCTAssertTrue(ready)
        XCTAssertFalse(MomentGate.shouldOpen(elapsed: 0.3, ready: ready))
        XCTAssertTrue(MomentGate.shouldOpen(elapsed: 0.6, ready: ready))
        // Timeout opens anyway.
        // Web's gate: the minimum, then up to 1.5 s MORE (~2.02 s worst case).
        XCTAssertFalse(MomentGate.shouldOpen(elapsed: 2.0, ready: false))
        XCTAssertTrue(MomentGate.shouldOpen(elapsed: 2.03, ready: false))
    }

    func test_gate_greenlogNeedsCompletedStatus_andTheSameBoard() {
        let g = MomentTrigger(kind: .greenlog, newLineIds: [])
        XCTAssertFalse(MomentGate.isReady(g, boardId: "b", board: board(), applyCount: 2, applyCountAtTrigger: 1))
        XCTAssertTrue(MomentGate.isReady(g, boardId: "b", board: board(status: .completed), applyCount: 2, applyCountAtTrigger: 1))
        // A pager swipe to another board is never ready.
        XCTAssertFalse(MomentGate.isReady(g, boardId: "b", board: board(status: .completed, id: "other"), applyCount: 2, applyCountAtTrigger: 1))
    }

    // MARK: Coalescing

    func test_coalesce_greenlogReplacesPendingBingo_bingoNeverReplaces() {
        let bingo = MomentTrigger(kind: .bingo, newLineIds: ["row_0"])
        let green = MomentTrigger(kind: .greenlog, newLineIds: ["col_2"])
        XCTAssertEqual(MomentGate.coalesce(pending: bingo, arriving: green),
                       MomentTrigger(kind: .greenlog, newLineIds: ["col_2", "row_0"]))
        XCTAssertEqual(MomentGate.coalesce(pending: green, arriving: bingo), green)
        XCTAssertEqual(MomentGate.coalesce(pending: bingo, arriving: MomentTrigger(kind: .bingo, newLineIds: ["col_1"])), bingo)
    }

    func test_nothingInterruptsAnOpenMoment() {
        XCTAssertTrue(MomentGate.shouldOpen(whileOpen: nil))
        XCTAssertFalse(MomentGate.shouldOpen(whileOpen: .bingo))
        XCTAssertFalse(MomentGate.shouldOpen(whileOpen: .greenlog))
    }

    // MARK: Start-a-new-board intent

    func test_startNewBoardIntent_postsTheNotificationMainTabViewObserves() {
        let exp = expectation(description: "intent")
        let token = NotificationCenter.default.addObserver(forName: .momentStartNewBoard, object: nil, queue: nil) { _ in exp.fulfill() }
        MomentIntent.startNewBoard()
        wait(for: [exp], timeout: 1)
        NotificationCenter.default.removeObserver(token)
    }

    // MARK: Pending lifecycle

    func test_disappearCancelsPending_andStaleChainExits() {
        let first = MomentPending(trigger: MomentTrigger(kind: .bingo, newLineIds: []), boardId: "b", applyCount: 0, start: Date())
        XCTAssertTrue(MomentGate.isLive(chain: first.id, pending: first))
        // Disappear sets the pending to nil → its chain exits.
        XCTAssertFalse(MomentGate.isLive(chain: first.id, pending: nil))
        // A newer pending within the 100 ms tick: the stale chain still exits.
        let second = MomentPending(trigger: MomentTrigger(kind: .bingo, newLineIds: []), boardId: "b", applyCount: 0, start: Date())
        XCTAssertFalse(MomentGate.isLive(chain: first.id, pending: second))
        XCTAssertTrue(MomentGate.isLive(chain: second.id, pending: second))
    }

    // MARK: Clock

    @MainActor
    func test_clockStop_midReplay_jumpsToTheFinalBeat() {
        let clock = MomentReplayClock()
        clock.stop() // never started: stays at 0
        XCTAssertEqual(clock.beat, 0)
        clock.start(finalBeat: 7, kind: .bingo)
        clock.stop()
        XCTAssertEqual(clock.beat, 7)
    }
}
