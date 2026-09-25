import XCTest
import GRDB
@testable import OYBC

/// Derived-counter freeze, Task 3 items 4 + 6 — every iOS RENDER / FILTER read
/// of a window-stamped derived counter agrees with the derivation kernel.
///
/// Owner repro shape: the member's root got logs AFTER the member's window
/// ended; the one-way latch (`isCompleted`) and the lifetime mirror
/// (`currentCount`) both say "complete", but the kernel (board stats, bingo)
/// sums only the root's increments inside the row's own `[startDate, endDate]`
/// and says incomplete. Before this change `BoardPreviewCells`, the play
/// view's windowed helpers, the VM's edit-preview completion + arrival
/// snapshot, the wizard preview, the Sources done-filter and the Counters hub
/// all read the latch / `currentCount − baseline`.
///
/// Twin of web `components/board/__tests__/windowStampedDerivedCells.test.ts`.
@MainActor
final class WindowStampedDerivedDisplayTests: XCTestCase {

    private let ws = "2026-09-14T00:00:00.000Z"
    private let we = "2026-09-20T23:59:59.999Z"
    private let rootId = "root"

    // MARK: - Fixtures

    private func makeTask(
        _ id: String, maxCount: Int, currentCount: Int, isCompleted: Bool,
        windowStamped: Bool = true, baseline: Int = 0, sharedCounterId: String? = "root"
    ) -> Task {
        Task(
            id: id, userId: "u1", title: id, type: .counting,
            action: "Read", unit: "pages", maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, currentCount: currentCount,
            createdAt: ws, updatedAt: ws, version: 1, isDeleted: false,
            startDate: windowStamped ? ws : nil, endDate: windowStamped ? we : nil,
            sharedCounterId: sharedCounterId, baseline: baseline,
            createdInWizard: windowStamped
        )
    }

    private var root: Task {
        makeTask(rootId, maxCount: 80, currentCount: 20, isCompleted: false,
                 windowStamped: false, sharedCounterId: nil)
    }
    /// Latch + mirror say 20/20 complete; the kernel says 3 of 20.
    private var latched: Task { makeTask("latched", maxCount: 20, currentCount: 20, isCompleted: true) }
    /// Latch says false, but 3 >= 3 in-window — the kernel says complete.
    private var met: Task { makeTask("met", maxCount: 3, currentCount: 0, isCompleted: false) }

    private func inc(_ id: String, _ delta: Int, _ at: String) -> TaskEvent {
        TaskEvent(
            id: id, userId: "u1", taskId: rootId, kind: .increment, delta: delta,
            occurredAt: at, boardId: nil, createdAt: at, updatedAt: at, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// +3 inside the window, +17 three days after it ended.
    private var events: [TaskEvent] {
        [inc("in", 3, "2026-09-16T18:00:00.000Z"), inc("late", 17, "2026-09-23T12:00:00.000Z")]
    }
    private var eventsByTaskId: [String: [TaskEvent]] { [rootId: events] }

    private func makeBoard() throws -> Board {
        let dict: [String: Any] = [
            "id": "wk", "userId": "u1", "name": "Last week", "status": BoardStatus.active.rawValue,
            "boardSize": 2, "timeframe": Timeframe.weekly.rawValue, "startDate": ws, "endDate": we,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 4, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": ws, "updatedAt": ws, "version": 1, "isDeleted": false,
        ]
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func place(_ taskId: String, col: Int) -> BoardTask {
        BoardTask(
            id: "bt-\(taskId)", boardId: "wk", taskId: taskId, row: 0, col: col, isCenter: false,
            createdAt: ws, updatedAt: ws, version: 1
        )
    }

    private var taskMap: [String: Task] {
        Dictionary(uniqueKeysWithValues: [root, latched, met].map { ($0.id, $0) })
    }

    /// Seeds a DB with the user, root, both members, their board, and the root's events.
    private func seededDb() throws -> AppDatabase {
        let database = try AppDatabase.makeTestInstance()
        let board = try makeBoard()
        try database.write { db in
            try User(
                id: "u1", email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: self.ws, updatedAt: self.ws, lastSyncedAt: nil, version: 1
            ).save(db)
            for t in [self.root, self.latched, self.met] { try t.save(db) }
            try board.save(db)
            try self.place("latched", col: 0).save(db)
            try self.place("met", col: 1).save(db)
            for e in self.events { try e.save(db) }
        }
        return database
    }

    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    // MARK: - Pure render surfaces

    func test_boardPreviewCells_paintOnlyTheMemberTheKernelCounts() throws {
        let board = try makeBoard()
        let placements = [place("latched", col: 0), place("met", col: 1)]
        let result = BoardPreviewCells.build(
            board: board, boardTasks: placements, taskMap: taskMap,
            childrenByCompound: [:], eventsByTaskId: eventsByTaskId
        )
        XCTAssertEqual(Array(result.cells.prefix(2)), [.task(completed: false), .task(completed: true)])

        let kernel = DerivationPass.computeBoardGrid(
            board: board, boardTasksOnBoard: placements, childrenByCompound: [:], taskById: taskMap,
            allBoards: [board], windowContext: WindowEvaluationContext(eventsByTaskId: eventsByTaskId)
        )
        XCTAssertEqual(kernel.cells.map { $0.isCompleted }, [false, true], "kernel agrees cell-by-cell")
    }

    func test_wizardPreviewIsCompleted_readsTheRootWindowSum() {
        func done(_ t: Task) -> Bool {
            wizardPreviewIsCompleted(
                task: t, taskById: taskMap, childrenByCompound: [:],
                eventsByTaskId: eventsByTaskId, windowStart: ws, windowEnd: nil
            )
        }
        XCTAssertFalse(done(latched))
        XCTAssertTrue(done(met))
    }

    func test_hubLinkedMember_keepsLatchAndBaselineMath() {
        let hub = makeTask("hub", maxCount: 10, currentCount: 20, isCompleted: true,
                           windowStamped: false, baseline: 5)
        let shown = resolveLinkedCounterDisplay(task: hub, eventsByTaskId: eventsByTaskId)
        XCTAssertEqual(shown.displayed, 15)
        XCTAssertTrue(shown.isCompleted)
    }

    // MARK: - DB-backed surfaces

    func test_playViewModel_editPreviewCompletionAndArrivalCount_matchTheKernel() throws {
        let database = try seededDb()
        let vm = BoardPlayViewModel(boardId: "wk", userId: "u1", database: database)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "wk" && !vm.allTasks.isEmpty && !vm.windowEventsByTaskId.isEmpty })

        XCTAssertFalse(vm.windowedIsCompleted(for: latched))
        XCTAssertTrue(vm.windowedIsCompleted(for: met))
        let squares = Dictionary(uniqueKeysWithValues: vm.sharedCounterArrivalSquares().map { ($0.taskId, $0.displayed) })
        XCTAssertEqual(squares, ["latched": 3, "met": 3])
    }

    func test_sourcesDoneFilter_countsOnlyTheMemberTheKernelCounts() throws {
        let database = try seededDb()
        let board = try makeBoard()
        let info = try database.read { db in try AppDatabase.resolveSupply(db: db, board: board) }
        XCTAssertEqual(info.doneTaskIds, ["met"])
    }

    func test_countersHub_logsTheWindowSumForWindowStampedMembers() throws {
        let database = try seededDb()
        let groups = database.fetchSharedCounterGroups(userId: "u1", showExpired: true).groups
        let group = try XCTUnwrap(groups.first { $0.counterId == rootId })
        let logged = Dictionary(uniqueKeysWithValues: group.tasks.map { ($0.taskId, $0.logged) })
        XCTAssertEqual(logged, [rootId: 20, "latched": 3, "met": 3])
        XCTAssertEqual(group.tasks.first { $0.taskId == "latched" }?.met, false)
    }
}
