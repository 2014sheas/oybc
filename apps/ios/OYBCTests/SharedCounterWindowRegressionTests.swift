import XCTest
import GRDB
@testable import OYBC

/// The owner's 2026-10-01 incident, end to end: a +5 logged on an ENDED but
/// unsealed September core board's "miles" square must not touch (or be
/// credited to) the CLOSED June board that borrows the same counter.
@MainActor
final class SharedCounterWindowRegressionTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let juneStart = "2026-06-01T00:00:00.000Z", juneEnd = "2026-06-30T00:00:00.000Z"
    private let septStart = "2026-09-01T00:00:00.000Z", septEnd = "2026-09-30T00:00:00.000Z"
    private let logNow = "2026-10-01T12:00:00.000Z"

    /// Root "miles" (2 in-window June miles); June monthly SEALED with a
    /// pre-rule hub-linked copy (goal 6); September monthly ended-unsealed
    /// with a window-stamped member (goal 30).
    private func seed() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(K.task("miles", maxCount: 100, currentCount: 2))
        try db.saveTask(K.task("june-miles", maxCount: 6, sharedCounterId: "miles", baseline: 0, currentCount: 2))
        try db.saveTask(K.task(
            "sept-miles", maxCount: 30, sharedCounterId: "miles",
            startDate: septStart, endDate: septEnd, createdInWizard: true, baseline: 2, currentCount: 2
        ))
        try db.saveBoard(K.board(id: "june", startDate: juneStart, endDate: juneEnd))
        try db.saveBoard(K.board(id: "sept", startDate: septStart, endDate: septEnd))
        try db.saveBoardTask(K.placement(id: "btJ", boardId: "june", taskId: "june-miles"))
        try db.saveBoardTask(K.placement(id: "btS", boardId: "sept", taskId: "sept-miles"))
        try K.addIncrement(db, taskId: "miles", delta: 2, occurredAt: "2026-06-10T00:00:00.000Z")
        XCTAssertTrue(try db.sealBoard(boardId: "june", now: "2026-07-02T00:00:00.000Z"))
        return db
    }

    func test_septemberLateLog_doesNotTouchOrCreditClosedJune() throws {
        let db = try seed()
        let juneBefore = try XCTUnwrap(db.fetchBoard(id: "june"))
        XCTAssertEqual(juneBefore.completedTasks, 0)

        // The heal (v37 / post-pull) rewrites June's hub-linked row.
        _ = try db.healLinkedCounterWindows(userId: K.userId)
        let juneRowBefore = try XCTUnwrap(K.fetchTask(db, "june-miles"))
        XCTAssertTrue(BoardSources.isWindowStampedForBoard(juneRowBefore, board: juneBefore))
        let juneVersionBefore = juneRowBefore.version
        let juneBoardVersionBefore = try XCTUnwrap(db.fetchBoard(id: "june")).version

        let result = try db.incrementSharedCounter(sourceTaskId: "miles", by: 5, boardId: "sept", now: logNow)

        // The event is stamped at September's late-log stamp (its endDate).
        let events = try db.read { try TaskEvent.filter(Column("taskId") == "miles" && Column("delta") == 5).fetchAll($0) }
        XCTAssertEqual(events.count, 1)
        let sept = try XCTUnwrap(db.fetchBoard(id: "sept"))
        XCTAssertEqual(
            DateFormatting.parseISO(events[0].occurredAt),
            DateFormatting.parseISO(lateLogOccurredAt(board: sept, nowIso: logNow))
        )
        XCTAssertEqual(DateFormatting.parseISO(events[0].occurredAt), DateFormatting.parseISO(septEnd))

        // Root lifetime cache +5.
        XCTAssertEqual(try K.fetchTask(db, "miles")?.currentCount, 7)

        // June: displayed count (June's window + sealedAt) stays 2.
        let june = try XCTUnwrap(db.fetchBoard(id: "june"))
        let juneRow = try XCTUnwrap(K.fetchTask(db, "june-miles"))
        let allEvents = try db.read { try TaskEvent.filter(Column("isDeleted") == false).fetchAll($0) }
        let byTask = Dictionary(grouping: allEvents, by: \.taskId)
        let shown = resolveLinkedCounterDisplay(
            task: juneRow, eventsByTaskId: byTask, sealedAt: june.sealedAt,
            window: LinkedCounterWindow(board: june)
        )
        XCTAssertEqual(shown.displayed, 2)
        XCTAssertFalse(shown.isCompleted)

        // June's sealed snapshot and stats are unchanged, and nothing was
        // written to its row / board by the propagation.
        XCTAssertEqual(june.completedTasks, 0)
        XCTAssertEqual(june.sealedCompletedCells ?? [], [])
        XCTAssertEqual(juneRow.version, juneVersionBefore, "no propagation write to June's row")
        XCTAssertEqual(june.version, juneBoardVersionBefore, "no cascade write to June's board")

        // September's member did count the log; June is not credited.
        XCTAssertFalse(result.affectedBoards.contains { $0.boardId == "june" })
        XCTAssertFalse(result.affectedBoards.contains { $0.boardId == "sept" },
                       "an ended board can no longer change — it isn't a credit target either")
    }

    /// The credit list never names a closed or ended board, even pre-heal.
    func test_creditList_excludesClosedAndEndedBoards() throws {
        let db = try seed()
        let result = try db.incrementSharedCounter(sourceTaskId: "miles", by: 1, boardId: "sept", now: logNow)
        XCTAssertTrue(result.affectedBoards.isEmpty)
    }

    func test_boardCanStillCountLogs_usesInstantsNotStrings() throws {
        let open = K.board(id: "o", startDate: "2026-10-01T00:00:00.000Z", endDate: "2026-10-31T00:00:00.000Z")
        XCTAssertTrue(AppDatabase.boardCanStillCountLogs(open, now: logNow))
        // Offset-less local ISO sorts differently than UTC as a string.
        let ended = K.board(id: "e", startDate: "2026-09-01T00:00:00", endDate: "2026-09-30T23:59:59")
        XCTAssertFalse(AppDatabase.boardCanStillCountLogs(ended, now: logNow))
        let sealed = K.board(id: "s", startDate: "2026-10-01T00:00:00.000Z", endDate: "2026-10-31T00:00:00.000Z",
                             sealedAt: "2026-10-01T06:00:00.000Z")
        XCTAssertFalse(AppDatabase.boardCanStillCountLogs(sealed, now: logNow))
    }

    /// Late log on a HEALED former hub-linked row of a closed board: it now
    /// routes to its ROOT (window-stamped) instead of the OQ2 no-op.
    func test_lateLogOnHealedRow_routesToRoot() throws {
        let db = try seed()
        _ = try db.healLinkedCounterWindows(userId: K.userId)
        try db.lateLogIncrement(boardId: "june", taskId: "june-miles", delta: 1, now: "2026-10-02T00:00:00.000Z")
        let ev = try db.read { try TaskEvent.filter(Column("taskId") == "miles" && Column("boardId") == "june").fetchAll($0) }
        XCTAssertEqual(ev.count, 1)
        XCTAssertEqual(DateFormatting.parseISO(ev[0].occurredAt), DateFormatting.parseISO(juneEnd))
        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: "june")).sealedCompletedCells ?? [], [], "3 < 6 — still not complete")
    }

    /// PRE-HEAL variant: June's row is still the UNSTAMPED hub-linked copy.
    /// The +5 on September writes June's lifetime latch (complete: 7 >= 6), but
    /// the kernel fallback alone — through the real grid path with June's SEALED
    /// context — still shows 2 miles and an incomplete cell.
    func test_preHeal_septemberLog_juneGridStillShowsTwo_viaKernelFallback() throws {
        let db = try seed()
        _ = try db.incrementSharedCounter(sourceTaskId: "miles", by: 5, boardId: "sept", now: logNow)

        let june = try XCTUnwrap(db.fetchBoard(id: "june"))
        let juneRow = try XCTUnwrap(K.fetchTask(db, "june-miles"))
        XCTAssertNil(juneRow.startDate, "still the unstamped hub-linked row (no heal ran)")

        let allEvents = try db.read { try TaskEvent.filter(Column("isDeleted") == false).fetchAll($0) }
        let byTask = Dictionary(grouping: allEvents, by: \.taskId)
        let sealedMs = try XCTUnwrap(DateFormatting.parseISO(try XCTUnwrap(june.sealedAt))).timeIntervalSince1970 * 1000
        let ctx = boundWindowContextAtSeal(eventsByTaskId: byTask, sealedAtMs: sealedMs)
        let root = try XCTUnwrap(K.fetchTask(db, "miles"))

        let result = DerivationPass.computeBoardGrid(
            board: june,
            boardTasksOnBoard: try db.fetchBoardTasks(boardId: "june"),
            childrenByCompound: [:],
            taskById: ["june-miles": juneRow, "miles": root],
            allBoards: [june],
            windowContext: ctx
        )
        XCTAssertEqual(result.cells.count, 1)
        XCTAssertFalse(result.cells[0].isCompleted, "2 in-window miles < 6 whatever the latch says")
        XCTAssertEqual(result.completedTasks, 0)

        let shown = resolveLinkedCounterDisplay(
            task: juneRow, eventsByTaskId: byTask, sealedAt: june.sealedAt,
            window: LinkedCounterWindow(board: june)
        )
        XCTAssertEqual(shown.displayed, 2)
        XCTAssertFalse(shown.isCompleted)
    }

    /// A sealed re-derivation after the heal where June's cell actually CHANGES:
    /// the old latch (7 >= 5) painted it green and the snapshot recorded it;
    /// only 2 miles fall in June, so the heal's re-derivation drops it.
    func test_heal_reDerivesSealedJune_cellDropsWhenLatchWasWrong() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(K.task("miles", maxCount: 100, currentCount: 7))
        try db.saveTask(K.task(
            "june-miles", maxCount: 5, sharedCounterId: "miles", baseline: 0, currentCount: 7, isCompleted: true
        ))
        try db.saveBoard(K.board(id: "june", startDate: juneStart, endDate: juneEnd))
        try db.saveBoardTask(K.placement(id: "btJ", boardId: "june", taskId: "june-miles"))
        try K.addIncrement(db, taskId: "miles", delta: 2, occurredAt: "2026-06-10T00:00:00.000Z")
        try K.addIncrement(db, taskId: "miles", delta: 5, occurredAt: "2026-09-10T00:00:00.000Z")
        XCTAssertTrue(try db.sealBoard(boardId: "june", now: "2026-07-02T00:00:00.000Z"))
        // Seal with the OLD latch's answer: the cell recorded as complete.
        try db.write {
            try $0.execute(sql: "UPDATE boards SET sealedCompletedCells = '[0]', completedTasks = 1 WHERE id = 'june'")
        }
        let before = try XCTUnwrap(db.fetchBoard(id: "june"))
        XCTAssertEqual(before.sealedCompletedCells ?? [], [0])
        XCTAssertEqual(before.completedTasks, 1)

        let r = try db.healLinkedCounterWindows(userId: K.userId)
        XCTAssertEqual(r.stamped, 1)

        let after = try XCTUnwrap(db.fetchBoard(id: "june"))
        XCTAssertEqual(after.sealedCompletedCells ?? [], [], "the snapshot no longer contains the cell")
        XCTAssertEqual(after.completedTasks, 0, "completedTasks dropped")
    }
}
