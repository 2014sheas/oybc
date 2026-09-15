import XCTest
import GRDB
@testable import OYBC

/// Covers the pager's synchronous window-commit seeding (owner-reported
/// jank fix, 2026-09-15): after the first `reload()` has populated
/// `coreBoardsByStart`, a `step()`/`jump()` must land on the target
/// window's FINAL state in the same frame — `isLoaded` stays true and
/// `board`/`draftBoard` reflect the map (playable / draft / empty)
/// BEFORE the background reconcile reload resolves. The pre-fix behavior
/// (drop to `isLoaded = false` + nil board) put a spinner up and
/// late-mounted the empty-window prompt, shifting layout.
@MainActor
final class CoreBoardWindowViewModelTests: XCTestCase {

    private let userId = "user-1"
    private let now = "2026-09-01T00:00:00.000"

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try db.write { grdb in
            try User(
                id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
            ).insert(grdb)
        }
        return db
    }

    /// Canonical monthly window boundaries for a reference date.
    private func monthWindow(_ ref: Date) -> (start: String, end: String) {
        let w = computeTimeframeBoundaries(
            timeframe: .monthly, referenceDate: ref, weekStartDay: "monday"
        )!
        return (wizardLocalISOString(w.start), wizardLocalISOString(w.end))
    }

    private func seedCoreBoard(
        _ db: AppDatabase, id: String, start: String, end: String, status: String
    ) throws {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Board \(id)",
            "status": status, "boardSize": 3, "timeframe": "monthly",
            "startDate": start, "endDate": end,
            "centerSquareType": "none", "isRandomized": true, "isCore": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1,
            "isDeleted": false,
        ]
        let board = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
        try db.write { grdb in try board.insert(grdb) }
    }

    /// Pumps the main run loop until the VM's async `reload()` lands
    /// (MainActor-safe: the test body runs on main, so pumping the run
    /// loop lets the VM's `DispatchQueue.main.async` commit execute).
    private func waitLoaded(_ vm: CoreBoardWindowViewModel, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !vm.isLoaded && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(vm.isLoaded, "VM reload did not land within \(timeout)s")
    }

    func test_stepAndJump_seedFinalStateSynchronously() throws {
        let db = try makeDb()

        // Three consecutive monthly windows: A = active board, B = draft,
        // C = empty (no row).
        let cal = Calendar.current
        let refA = cal.date(from: DateComponents(year: 2026, month: 9, day: 10))!
        let refB = cal.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        let winA = monthWindow(refA)
        let winB = monthWindow(refB)
        try seedCoreBoard(db, id: "board-a", start: winA.start, end: winA.end, status: "active")
        try seedCoreBoard(db, id: "board-b", start: winB.start, end: winB.end, status: "draft")

        let vm = CoreBoardWindowViewModel(
            timeframe: .monthly,
            seedWindowStart: winA.start,
            userId: userId,
            weekStartDay: "monday",
            database: db
        )
        vm.reload()
        waitLoaded(vm)
        XCTAssertEqual(vm.board?.id, "board-a")
        XCTAssertNil(vm.draftBoard)

        // Step to October (draft): the DRAFT must be seeded in the same
        // frame — no isLoaded drop, no transient nil/nil (which rendered
        // the EMPTY prompt pre-fix), correct draft-vs-playable split.
        vm.step(1)
        XCTAssertTrue(vm.isLoaded, "stepping must not drop back to the spinner")
        XCTAssertNil(vm.board)
        XCTAssertEqual(vm.draftBoard?.id, "board-b", "draft seeds into draftBoard, never board")

        // Step to November (no row): empty state — synchronously, with
        // isLoaded still true so the prompt (+ hint) mounts in one frame.
        vm.step(1)
        XCTAssertTrue(vm.isLoaded)
        XCTAssertNil(vm.board)
        XCTAssertNil(vm.draftBoard)

        // Jump straight back to September: the playable board seeds
        // synchronously through the same commit path.
        vm.jump(toWindowStart: winA.start)
        XCTAssertTrue(vm.isLoaded)
        XCTAssertEqual(vm.board?.id, "board-a")
        XCTAssertNil(vm.draftBoard)

        // And the background reconcile agrees with the seed. (`isLoaded`
        // never drops post-fix, so `waitLoaded` would return instantly —
        // pump the run loop long enough for the reconcile to land.)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(vm.board?.id, "board-a")
        XCTAssertNil(vm.draftBoard)
    }
}
