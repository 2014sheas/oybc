import XCTest
import GRDB
@testable import OYBC

/// Counter Detail's "Tasks on boards" member cards, through the page's own
/// load (`CounterDetailView.loadSnapshot`):
///   - each placed member shows its count inside ITS board's window (the play
///     cell's number), never the lifetime total — a board-born root placed on
///     a board included; the hero total stays lifetime;
///   - the page's "Show expired tasks" toggle: expired members hidden by
///     default, listed when on; a member on an open board always listed.
/// Web twin: `hooks/__tests__/sharedCounterGroupsWindowCount.test.ts`
@MainActor
final class CounterDetailMembersTests: XCTestCase {
    private typealias K = LinkedWindowKit
    // This week (open) and last week (ended).
    private let wStart = "2026-10-05T00:00:00.000", wEnd = "2099-12-31T23:59:59.999"
    private let eStart = "2026-09-28T00:00:00.000", eEnd = "2026-10-04T23:59:59.999"

    private func load(_ db: AppDatabase, showExpired: Bool) -> CounterDetailView.Snapshot {
        CounterDetailView.loadSnapshot(
            database: db, userId: K.userId, counterId: "root", showExpired: showExpired,
            now: AppDatabase.currentTimestamp()
        )
    }

    /// Root R (lifetime 10): +7 last week, +3 this week. `m-w` hub-linked on
    /// this week's board; `m-e` a window-stamped member of last week's board.
    private func seed(rootPlacedOnW: Bool) throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var root = K.task("root", maxCount: 5, currentCount: 10, title: "Run miles")
        root.isCounter = !rootPlacedOnW
        try db.saveTask(root)
        try db.saveTask(K.task("m-w", maxCount: 4, sharedCounterId: "root", baseline: 0, currentCount: 10))
        try db.saveTask(K.task(
            "m-e", maxCount: 8, sharedCounterId: "root", startDate: eStart, endDate: eEnd,
            createdInWizard: true, baseline: 0, currentCount: 10
        ))
        try db.saveBoard(K.board(id: "b-w", startDate: wStart, endDate: wEnd, timeframe: .weekly))
        try db.saveBoard(K.board(id: "b-e", startDate: eStart, endDate: eEnd, timeframe: .weekly))
        try db.saveBoardTask(K.placement(id: "bt-w", boardId: "b-w", taskId: "m-w"))
        try db.saveBoardTask(K.placement(id: "bt-e", boardId: "b-e", taskId: "m-e"))
        if rootPlacedOnW {
            try db.saveBoardTask(K.placement(id: "bt-r", boardId: "b-w", taskId: "root", cell: 1, size: 2))
        }
        try K.addIncrement(db, taskId: "root", delta: 7, occurredAt: "2026-09-30T12:00:00.000Z")
        try K.addIncrement(db, taskId: "root", delta: 3, occurredAt: "2026-10-06T12:00:00.000Z")
        return db
    }

    private func logged(_ snap: CounterDetailView.Snapshot) -> [String: CountValue] {
        Dictionary(uniqueKeysWithValues: (snap.group?.tasks ?? []).map { ($0.taskId, $0.logged) })
    }

    func test_memberCards_showEachBoardWindow_notLifetime() throws {
        let snap = load(try seed(rootPlacedOnW: false), showExpired: true)
        XCTAssertEqual(snap.group?.lifetime, 10)
        XCTAssertEqual(logged(snap)["m-w"], 3)
        XCTAssertEqual(logged(snap)["m-e"], 7)
        // The unplaced hub-born root has no window: lifetime.
        XCTAssertEqual(logged(snap)["root"], 10)
    }

    func test_boardBornRoot_placedOnThisWeek_shows3_notLifetime10() throws {
        let snap = load(try seed(rootPlacedOnW: true), showExpired: true)
        let rootRow = try XCTUnwrap(snap.group?.tasks.first { $0.taskId == "root" })
        XCTAssertEqual(rootRow.boardId, "b-w")
        XCTAssertEqual(rootRow.logged, 3)
        XCTAssertEqual(rootRow.goal, 5)
        XCTAssertFalse(rootRow.met)
        XCTAssertEqual(snap.group?.lifetime, 10)
    }

    func test_showExpired_off_hidesTheExpiredMember_openBoardMemberStays() throws {
        let ids = Set((load(try seed(rootPlacedOnW: false), showExpired: false).group?.tasks ?? []).map(\.taskId))
        XCTAssertEqual(ids, ["root", "m-w"])
    }

    func test_showExpired_on_listsTheExpiredMember_lifetimeUnchanged() throws {
        let db = try seed(rootPlacedOnW: false)
        let on = load(db, showExpired: true)
        XCTAssertEqual(Set((on.group?.tasks ?? []).map(\.taskId)), ["root", "m-w", "m-e"])
        XCTAssertEqual(on.group?.lifetime, load(db, showExpired: false).group?.lifetime)
    }
}
