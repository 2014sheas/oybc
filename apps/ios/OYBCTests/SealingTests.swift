import XCTest
import GRDB
@testable import OYBC

/// Windowed Completion PR C — board sealing engine (docs/WINDOWED_COMPLETION.md
/// §Sealing + §Testing matrix sealing rows). Twin of web's `sealing.test.ts`.
/// Covers: the seal transaction (snapshot stored, idempotent, upper bound); the
/// backstop keyed off max(endDate, activatedAt) incl. the draft-grace rule;
/// migration sealing; fan-out exclusion (a live event doesn't repaint a sealed
/// board); re-derivation determinism. All against `AppDatabase.makeTestInstance()`.
@MainActor
final class SealingTests: XCTestCase {

    private let userId = "u1"

    // A daily window: 07-01 → 07-02 → backstop 6h → deadline 07-02T06:00.
    private let start = "2026-07-01T00:00:00.000Z"
    private let end = "2026-07-02T00:00:00.000Z"
    private let inWindow = "2026-07-01T12:00:00.000Z"
    private let pastBackstop = "2026-07-02T07:00:00.000Z" // > end + 6h

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeTask(_ id: String, isCompleted: Bool = false, completedAt: String? = nil) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: "N", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil, isOrdered: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            parentStepId: nil, parentStepIndex: nil, progressCounters: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, completedAt: completedAt ?? (isCompleted ? now : nil),
            currentCount: nil, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 3, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        )
    }

    /// A plain (non-shared) COUNTING task — M-3: slice 1's SealingTests only
    /// covered NORMAL; these tests cover the delta/increment-event path.
    private func makeCountingTask(_ id: String, maxCount: Int, currentCount: Int? = nil) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: "C", description: nil, type: .counting,
            action: "Pushups", unit: "reps", maxCount: maxCount, operatorType: nil, threshold: nil, isOrdered: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            parentStepId: nil, parentStepIndex: nil, progressCounters: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil,
            currentCount: currentCount, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 3, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        )
    }

    private func makeIncrementEvent(_ id: String, taskId: String, occurredAt: String, delta: Int, isDeleted: Bool = false) -> TaskEvent {
        let now = AppDatabase.currentTimestamp()
        return TaskEvent(
            id: id, userId: userId, taskId: taskId, kind: .increment, delta: delta,
            occurredAt: occurredAt, boardId: nil, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    /// Build a 1×1 daily board, optionally sealed / with activatedAt.
    private func makeBoard(
        id: String, startDate: String? = nil, endDate: String? = nil,
        status: BoardStatus = .active, sealedAt: String? = nil,
        sealedCompletedCells: [Int]? = nil, activatedAt: String? = nil, size: Int = 1
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "B", "status": status.rawValue,
            "boardSize": size, "timeframe": Timeframe.daily.rawValue,
            "startDate": startDate ?? start, "endDate": endDate ?? end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        if let activatedAt { dict["activatedAt"] = activatedAt }
        // sealedCompletedCells decodes from a JSON STRING (like completedLineIds).
        if let cells = sealedCompletedCells,
           let data = try? JSONEncoder().encode(cells),
           let str = String(data: data, encoding: .utf8) {
            dict["sealedCompletedCells"] = str
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String, cell: Int = 0, size: Int = 1) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: cell / size, col: cell % size,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func makeEvent(_ id: String, taskId: String, occurredAt: String, isDeleted: Bool = false) -> TaskEvent {
        let now = AppDatabase.currentTimestamp()
        return TaskEvent(
            id: id, userId: userId, taskId: taskId, kind: .completion, delta: nil,
            occurredAt: occurredAt, boardId: nil, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    private func fetchBoard(_ db: AppDatabase, _ id: String) throws -> Board { try db.fetchBoard(id: id)! }

    // MARK: - seal transaction

    func test_sealBoard_freezesSnapshotAndStampsSealedAt() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        try db.write { try self.makeEvent("e1", taskId: "t1", occurredAt: self.inWindow).save($0) }

        let sealed = try db.sealBoard(boardId: "b1", now: pastBackstop)
        XCTAssertTrue(sealed)

        let board = try fetchBoard(db, "b1")
        XCTAssertEqual(board.sealedAt, pastBackstop)
        XCTAssertEqual(board.sealedCompletedCells, [0])
        XCTAssertEqual(board.completedTasks, 1)
        XCTAssertEqual(board.version, 2)
        XCTAssertEqual(board.status, .active) // sealing leaves status untouched

        let queued = try db.read { try SyncQueueItem.filter(Column("entityId") == "b1" && Column("entityType") == "boards").fetchCount($0) }
        XCTAssertGreaterThan(queued, 0)
    }

    func test_sealBoard_isIdempotent() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        try db.write { try self.makeEvent("e1", taskId: "t1", occurredAt: self.inWindow).save($0) }

        XCTAssertTrue(try db.sealBoard(boardId: "b1", now: pastBackstop))
        let first = try fetchBoard(db, "b1")
        XCTAssertFalse(try db.sealBoard(boardId: "b1", now: "2026-07-03T00:00:00.000Z"))
        let second = try fetchBoard(db, "b1")
        XCTAssertEqual(second.sealedAt, first.sealedAt)
        XCTAssertEqual(second.version, first.version)
    }

    func test_sealBoard_excludesPostSealEvents() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        // Event AFTER the seal instant → belongs to a later window, must not count.
        try db.write { try self.makeEvent("e-late", taskId: "t1", occurredAt: "2026-07-05T00:00:00.000Z").save($0) }

        try db.sealBoard(boardId: "b1", now: pastBackstop)
        let board = try fetchBoard(db, "b1")
        XCTAssertEqual(board.sealedCompletedCells, [])
        XCTAssertEqual(board.completedTasks, 0)
    }

    // MARK: - backstop auto-seal

    func test_backstop_sealsPastDeadlineLeavesInWindow() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b-sealed", startDate: start, endDate: end))
        try db.saveBoard(makeBoard(id: "b-live",
                                   startDate: "2026-07-02T00:00:00.000Z",
                                   endDate: "2026-07-03T00:00:00.000Z"))

        let ids = try db.runBackstopAutoSeal(userId: userId, now: pastBackstop)
        XCTAssertEqual(ids, ["b-sealed"])
        XCTAssertEqual(try fetchBoard(db, "b-sealed").sealedAt, pastBackstop)
        XCTAssertNil(try fetchBoard(db, "b-live").sealedAt)
    }

    func test_backstop_draftGraceKeysOffActivatedAt() throws {
        let db = try makeDb(); try seedUser(db)
        let activatedAt = "2026-07-04T00:00:00.000Z"
        try db.saveBoard(makeBoard(id: "b1", startDate: start, endDate: end, activatedAt: activatedAt))

        // Past endDate+6h but grace keys off activatedAt → still unsealed.
        XCTAssertEqual(try db.runBackstopAutoSeal(userId: userId, now: pastBackstop), [])
        XCTAssertNil(try fetchBoard(db, "b1").sealedAt)

        // Only past activatedAt + 6h does it auto-seal.
        let late = try db.runBackstopAutoSeal(userId: userId, now: "2026-07-04T07:00:00.000Z")
        XCTAssertEqual(late, ["b1"])
        XCTAssertEqual(try fetchBoard(db, "b1").sealedAt, "2026-07-04T07:00:00.000Z")
    }

    func test_backstop_neverSealsDraft() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", status: .draft))
        XCTAssertEqual(try db.runBackstopAutoSeal(userId: userId, now: pastBackstop), [])
    }

    // MARK: - migration sealing

    func test_migrationSealing_sealsExpiredFromLifetime() throws {
        let db = try makeDb(); try seedUser(db)
        let ancientStart = "2020-01-01T00:00:00.000Z"
        let ancientEnd = "2020-01-02T00:00:00.000Z"
        try db.saveTask(makeTask("t1", isCompleted: true, completedAt: ancientStart))
        try db.saveBoard(makeBoard(id: "b-old", startDate: ancientStart, endDate: ancientEnd))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b-old", taskId: "t1"))

        // A future live board — not past backstop.
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(30 * 24 * 3600))
        let futureEnd = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60 * 24 * 3600))
        try db.saveBoard(makeBoard(id: "b-future", startDate: future, endDate: futureEnd))

        let now = AppDatabase.currentTimestamp()
        try db.write { try AppDatabase.sealExpiredBoardsAtMigration(db: $0, now: now) }

        let old = try fetchBoard(db, "b-old")
        XCTAssertNotNil(old.sealedAt)
        XCTAssertEqual(old.sealedCompletedCells, [0]) // lifetime-complete
        XCTAssertEqual(old.completedTasks, 1)
        XCTAssertNil(try fetchBoard(db, "b-future").sealedAt)
    }

    // MARK: - fan-out exclusion (live event doesn't repaint a sealed board)

    func test_fanOutExclusion_liveCompletionDoesNotRepaintSealedBoard() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        // Sealed board places t1 (grey at seal time).
        try db.saveBoard(makeBoard(id: "b-sealed", sealedAt: pastBackstop, sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-s", boardId: "b-sealed", taskId: "t1"))
        // Live board (later window) also places t1.
        try db.saveBoard(makeBoard(id: "b-live",
                                   startDate: "2026-07-02T00:00:00.000Z",
                                   endDate: "2026-07-03T00:00:00.000Z"))
        let btLive = makeBoardTask(id: "bt-l", boardId: "b-live", taskId: "t1")
        try db.saveBoardTask(btLive)

        // Complete t1 on the LIVE board.
        _ = try db.completeTaskOrchestrated(
            board: try fetchBoard(db, "b-live"), taskId: "t1",
            intent: .setCompleted(true), boardTask: btLive, now: "2026-07-02T12:00:00.000Z"
        )

        XCTAssertEqual(try fetchBoard(db, "b-live").completedTasks, 1)
        // Sealed board frozen snapshot is unchanged.
        let sealed = try fetchBoard(db, "b-sealed")
        XCTAssertEqual(sealed.sealedCompletedCells, [])
        XCTAssertEqual(sealed.completedTasks, 0)
    }

    // MARK: - pull-path seal re-derivation

    func test_reDerivation_latePreSealEventPaintsGreenLocally() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "b-sealed", sealedAt: pastBackstop, sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-s", boardId: "b-sealed", taskId: "t1"))

        // A late pre-seal event arrives; re-derive.
        try db.write { db in
            try self.makeEvent("e-late", taskId: "t1", occurredAt: self.inWindow).save(db)
            try AppDatabase.reDeriveSealedBoards(db: db, changedTaskIds: ["t1"])
        }

        let sealed = try fetchBoard(db, "b-sealed")
        XCTAssertEqual(sealed.sealedCompletedCells, [0])
        XCTAssertEqual(sealed.completedTasks, 1)
        // Local-only: version NOT bumped, no board sync enqueued.
        XCTAssertEqual(sealed.version, 1)
        let queued = try db.read { try SyncQueueItem.filter(Column("entityId") == "b-sealed" && Column("entityType") == "boards").fetchCount($0) }
        XCTAssertEqual(queued, 0)
    }

    func test_reDerivation_postSealEventDoesNotBleed() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "b-sealed", sealedAt: pastBackstop, sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-s", boardId: "b-sealed", taskId: "t1"))

        try db.write { db in
            try self.makeEvent("e-after", taskId: "t1", occurredAt: "2026-07-10T00:00:00.000Z").save(db)
            try AppDatabase.reDeriveSealedBoards(db: db, changedTaskIds: ["t1"])
        }

        let sealed = try fetchBoard(db, "b-sealed")
        XCTAssertEqual(sealed.sealedCompletedCells, [])
        XCTAssertEqual(sealed.completedTasks, 0)
    }

    func test_reDerivation_isOrderIndependent() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        try db.saveBoard(makeBoard(id: "b-sealed", sealedAt: pastBackstop, sealedCompletedCells: [], size: 3))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b-sealed", taskId: "t1", cell: 0, size: 3))
        try db.saveBoardTask(makeBoardTask(id: "bt2", boardId: "b-sealed", taskId: "t2", cell: 1, size: 3))
        try db.write { db in
            try self.makeEvent("e-a", taskId: "t1", occurredAt: self.inWindow).save(db)
            try self.makeEvent("e-b", taskId: "t2", occurredAt: "2026-07-01T18:00:00.000Z").save(db)
        }

        try db.write { try AppDatabase.reDeriveSealedBoards(db: $0, changedTaskIds: ["t1", "t2"]) }
        let once = try fetchBoard(db, "b-sealed").sealedCompletedCells
        try db.write { try AppDatabase.reDeriveSealedBoards(db: $0, changedTaskIds: ["t2", "t1"]) }
        let twice = try fetchBoard(db, "b-sealed").sealedCompletedCells

        XCTAssertEqual(once, [0, 1])
        XCTAssertEqual(twice, once)
    }

    // MARK: - COUNTING seal-snapshot + re-derivation (M-3 — slice 1 covered only NORMAL)

    func test_sealBoard_countingSnapshotsGreenWhenInWindowSumMeetsGoal() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeCountingTask("t-count", maxCount: 3))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t-count"))
        try db.write { db in
            try self.makeIncrementEvent("e1", taskId: "t-count", occurredAt: self.inWindow, delta: 2).save(db)
            try self.makeIncrementEvent("e2", taskId: "t-count", occurredAt: self.inWindow, delta: 1).save(db)
        }

        let sealed = try db.sealBoard(boardId: "b1", now: pastBackstop)
        XCTAssertTrue(sealed)
        let board = try fetchBoard(db, "b1")
        XCTAssertEqual(board.sealedCompletedCells, [0]) // 3/3 in-window → green
        XCTAssertEqual(board.completedTasks, 1)
    }

    func test_sealBoard_countingSnapshotsGreyWhenBelowGoal() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeCountingTask("t-count", maxCount: 3))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t-count"))
        try db.write { try self.makeIncrementEvent("e1", taskId: "t-count", occurredAt: self.inWindow, delta: 2).save($0) }

        try db.sealBoard(boardId: "b1", now: pastBackstop)
        let board = try fetchBoard(db, "b1")
        XCTAssertEqual(board.sealedCompletedCells, []) // 2/3 in-window → not met
        XCTAssertEqual(board.completedTasks, 0)
    }

    func test_sealBoard_countingExcludesPostSealIncrements() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeCountingTask("t-count", maxCount: 3))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t-count"))
        try db.write { db in
            try self.makeIncrementEvent("e1", taskId: "t-count", occurredAt: self.inWindow, delta: 2).save(db)
            // After the seal instant → belongs to a later window, must not count.
            try self.makeIncrementEvent("e-late", taskId: "t-count", occurredAt: "2026-07-05T00:00:00.000Z", delta: 5).save(db)
        }

        try db.sealBoard(boardId: "b1", now: pastBackstop)
        let board = try fetchBoard(db, "b1")
        XCTAssertEqual(board.sealedCompletedCells, [])
        XCTAssertEqual(board.completedTasks, 0)
    }

    /// I-1 — migration bleed-greens converge to windowed truth (docs
    /// §Migration → "Migration bleed-greens converge to windowed truth"),
    /// COUNTING flavor. The migration path seals from the pre-migration
    /// LIFETIME `currentCount` cache (no window context) — a counting task
    /// whose lifetime count met the goal BEFORE this board's window opened
    /// freezes green (the bleed). The first post-migration re-derivation
    /// (pull-path `reDeriveSealedBoards`) recomputes from the WINDOWED event
    /// union bounded at `sealedAt` — the bleed flips grey once the in-window
    /// sum no longer meets the goal.
    func test_reDerivation_countingBleedFlipsGreyUnderWindowedReDerivation() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeCountingTask("t-count", maxCount: 3))
        // Migration-style seal: lifetime bleed green, no events yet.
        try db.saveBoard(makeBoard(id: "b-sealed", sealedAt: pastBackstop, sealedCompletedCells: [0]))
        try db.saveBoardTask(makeBoardTask(id: "bt-s", boardId: "b-sealed", taskId: "t-count"))

        // The only increments pre-date the window entirely (windowed sum = 0 < goal).
        try db.write { db in
            try self.makeIncrementEvent("e-a", taskId: "t-count", occurredAt: "2026-06-30T09:00:00.000Z", delta: 2).save(db)
            try self.makeIncrementEvent("e-b", taskId: "t-count", occurredAt: "2026-06-30T10:00:00.000Z", delta: 1).save(db)
            try AppDatabase.reDeriveSealedBoards(db: db, changedTaskIds: ["t-count"])
        }

        let board = try fetchBoard(db, "b-sealed")
        XCTAssertEqual(board.sealedCompletedCells, []) // bleed converged to windowed truth
        XCTAssertEqual(board.completedTasks, 0)
        // Local-only: version NOT bumped.
        XCTAssertEqual(board.version, 1)
    }

    func test_reDerivation_countingInWindowIncrementsPaintGreen() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeCountingTask("t-count", maxCount: 3))
        try db.saveBoard(makeBoard(id: "b-sealed", sealedAt: pastBackstop, sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-s", boardId: "b-sealed", taskId: "t-count"))

        // Late pre-seal increments arrive that DO sum to the goal in-window.
        try db.write { db in
            try self.makeIncrementEvent("e-a", taskId: "t-count", occurredAt: self.inWindow, delta: 2).save(db)
            try self.makeIncrementEvent("e-b", taskId: "t-count", occurredAt: self.inWindow, delta: 1).save(db)
            try AppDatabase.reDeriveSealedBoards(db: db, changedTaskIds: ["t-count"])
        }

        let board = try fetchBoard(db, "b-sealed")
        XCTAssertEqual(board.sealedCompletedCells, [0])
        XCTAssertEqual(board.completedTasks, 1)
    }
}
