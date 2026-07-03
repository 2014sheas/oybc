import XCTest
import GRDB
@testable import OYBC

/// Tests for `AppDatabase.decrementSharedCounter(sourceTaskId:by:)` (Phase 2).
///
/// Covers the four invariants called out in the spec:
///   1. Clamp-to-0 — `eff = min(by, source.currentCount)`.
///   2. No-op at 0 — when source count is 0, returns effectiveDelta == 0 + empty affectedBoards.
///   3. ONE-WAY LATCH — decrement never un-completes a task.
///   4. affectedBoards — ACTIVE boards containing any member task of the group appear in the result.
///
/// Each test spins up its own `AppDatabase.makeTestInstance()` (in-memory, full migration chain)
/// so tests are isolated and schema-identical to production.
final class AppDatabaseSharedCounterDecrementTests: XCTestCase {

    // MARK: - Helpers

    private func makeDb() throws -> AppDatabase {
        try AppDatabase.makeTestInstance()
    }

    private func seedUser(_ db: AppDatabase, id: String = "u1") throws {
        let now = AppDatabase.currentTimestamp()
        let user = User(
            id: id,
            email: "test@example.com",
            displayName: "Test User",
            photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1
        )
        try db.saveUser(user)
    }

    /// Minimal COUNTING source task (no sharedCounterId → it IS the source).
    private func makeSourceTask(
        id: String,
        userId: String = "u1",
        currentCount: Int = 10,
        maxCount: Int = 20,
        isCompleted: Bool = false,
        completedAt: String? = nil
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: userId,
            title: "Test Counter \(id)",
            description: nil,
            type: .counting,
            action: "Do",
            unit: "reps",
            maxCount: maxCount,
            operatorType: nil,
            threshold: nil,
            isOrdered: nil,
            referencedBoardId: nil,
            referencedTemplateId: nil,
            achievementTrigger: nil,
            requiredCount: nil,
            parentStepId: nil,
            parentStepIndex: nil,
            progressCounters: nil,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: isCompleted,
            completedAt: completedAt,
            currentCount: currentCount,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil,
            timeframe: nil,
            startDate: nil,
            endDate: nil,
            sharedCounterId: nil,
            baseline: nil,
            lastSyncedCount: nil,
            createdInWizard: false
        )
    }

    /// Minimal COUNTING linked task (sharedCounterId → linked/derived).
    private func makeLinkedTask(
        id: String,
        sourceId: String,
        userId: String = "u1",
        baseline: Int = 0,
        maxCount: Int = 10,
        isCompleted: Bool = false
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: userId,
            title: "Linked Counter \(id)",
            description: nil,
            type: .counting,
            action: "Do",
            unit: "reps",
            maxCount: maxCount,
            operatorType: nil,
            threshold: nil,
            isOrdered: nil,
            referencedBoardId: nil,
            referencedTemplateId: nil,
            achievementTrigger: nil,
            requiredCount: nil,
            parentStepId: nil,
            parentStepIndex: nil,
            progressCounters: nil,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: isCompleted,
            completedAt: nil,
            currentCount: nil,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil,
            timeframe: nil,
            startDate: nil,
            endDate: nil,
            sharedCounterId: sourceId,
            baseline: baseline,
            lastSyncedCount: nil,
            createdInWizard: false
        )
    }

    /// ACTIVE board via JSON (mirrors `IndefiniteBoardTests.makeBoard`).
    private func makeBoard(id: String, name: String, userId: String = "u1") -> Board {
        let dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": name,
            "status": BoardStatus.active.rawValue,
            "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000",
            "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1,
            "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(boardId: String, taskId: String) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: UUID().uuidString,
            boardId: boardId,
            taskId: taskId,
            row: 0,
            col: 0,
            isCenter: false,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1
        )
    }

    // MARK: - 1. Clamp-to-0

    /// When `by > source.currentCount`, `eff` is clamped to `source.currentCount`
    /// and that clamped value is returned as `effectiveDelta`.
    func test_clampToZero_decrementLargerThanCount() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeSourceTask(id: "src-1", currentCount: 3, maxCount: 20)
        try db.saveTask(source)

        let result = try db.decrementSharedCounter(sourceTaskId: "src-1", by: 5)

        // eff = min(5, 3) = 3
        XCTAssertEqual(result.effectiveDelta, 3, "effectiveDelta must be clamped to the source count")

        // Source count is now 0
        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-1") })
        XCTAssertEqual(fetched.currentCount, 0)
    }

    func test_decrementExact_matchesCount() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeSourceTask(id: "src-2", currentCount: 7, maxCount: 20)
        try db.saveTask(source)

        // Decrementing by exactly source.currentCount
        let result = try db.decrementSharedCounter(sourceTaskId: "src-2", by: 7)

        XCTAssertEqual(result.effectiveDelta, 7)
        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-2") })
        XCTAssertEqual(fetched.currentCount, 0)
    }

    func test_decrementPartial_reducesCount() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeSourceTask(id: "src-3", currentCount: 10, maxCount: 20)
        try db.saveTask(source)

        let result = try db.decrementSharedCounter(sourceTaskId: "src-3", by: 3)

        XCTAssertEqual(result.effectiveDelta, 3)
        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-3") })
        XCTAssertEqual(fetched.currentCount, 7)
    }

    // MARK: - 2. No-op at 0

    /// When `source.currentCount == 0`, `eff = min(1, 0) = 0` → no-op:
    /// `effectiveDelta` is 0, `affectedBoards` is empty, source row is unchanged.
    func test_noOpAtZero_returnsZeroDeltaAndNoBoards() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeSourceTask(id: "src-zero", currentCount: 0, maxCount: 10)
        try db.saveTask(source)

        let result = try db.decrementSharedCounter(sourceTaskId: "src-zero", by: 1)

        XCTAssertEqual(result.effectiveDelta, 0, "No-op at 0 must return effectiveDelta == 0")
        XCTAssertTrue(result.affectedBoards.isEmpty, "No-op at 0 must return empty affectedBoards")

        // Source row must not have been mutated
        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-zero") })
        XCTAssertEqual(fetched.currentCount, 0)
        XCTAssertEqual(fetched.version, 1, "version must not be incremented on a no-op")
    }

    // MARK: - 3. ONE-WAY LATCH

    /// A source task that is already `isCompleted = true` must stay completed
    /// after a decrement. The latch is one-way — decrement NEVER un-completes.
    func test_latchPreserved_sourceStaysCompleted() throws {
        let db = try makeDb()
        try seedUser(db)

        let completedAt = "2026-06-15T10:00:00.000Z"
        let source = makeSourceTask(
            id: "src-latch",
            currentCount: 5,
            maxCount: 5,       // was at goal when completed
            isCompleted: true,
            completedAt: completedAt
        )
        try db.saveTask(source)

        let result = try db.decrementSharedCounter(sourceTaskId: "src-latch", by: 3)

        XCTAssertEqual(result.effectiveDelta, 3)

        // Source must still be completed even though count dropped below maxCount
        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-latch") })
        XCTAssertEqual(fetched.currentCount, 2)
        XCTAssertTrue(fetched.isCompleted, "ONE-WAY LATCH: isCompleted must remain true after decrement")
        XCTAssertEqual(fetched.completedAt, completedAt, "completedAt must be preserved (not cleared)")
    }

    /// A LINKED task that is already `isCompleted = true` must stay completed
    /// after the source is decremented (same latch rule, different node).
    func test_latchPreserved_linkedTaskStaysCompleted() throws {
        let db = try makeDb()
        try seedUser(db)

        // Source starts at 15
        let source = makeSourceTask(id: "src-link-latch", currentCount: 15, maxCount: 100)
        try db.saveTask(source)

        // Linked task has baseline=0, maxCount=10 → displayed = sourceCount - 0.
        // At source=15, displayed=15 ≥ 10 → was completed. We mark it as such.
        var linked = makeLinkedTask(id: "lnk-1", sourceId: "src-link-latch", baseline: 0, maxCount: 10)
        linked.isCompleted = true
        linked.completedAt = "2026-06-10T08:00:00.000Z"
        try db.saveTask(linked)

        // Decrement source to 8 — displayed would become 8 < 10, so it's no longer "earned"
        // in a forward-looking sense, BUT the latch must hold.
        let result = try db.decrementSharedCounter(sourceTaskId: "src-link-latch", by: 7)

        XCTAssertEqual(result.effectiveDelta, 7)

        let fetchedLinked = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "lnk-1") })
        XCTAssertTrue(fetchedLinked.isCompleted, "ONE-WAY LATCH: linked task must remain completed after source decrement")
        XCTAssertNotNil(fetchedLinked.completedAt, "completedAt must not be cleared")
    }

    /// Regression: a linked task whose displayed value already meets its goal
    /// but was left un-latched (e.g. a sync-conflict reset of `isCompleted`)
    /// FIRST completes during a decrement — `completedAt` must be set alongside
    /// `isCompleted`. The bug: the newly-completing check read the POST-overwrite
    /// `isCompleted` (always false), so the row persisted `isCompleted=true` with
    /// `completedAt=nil`, breaking the `isCompleted ⟹ completedAt` invariant.
    func test_linkedTask_firstCompletesOnDecrement_setsCompletedAt() throws {
        let db = try makeDb()
        try seedUser(db)

        // Source at 15; linked baseline=0, maxCount=10 → displayed=15 ≥ 10.
        let source = makeSourceTask(id: "src-first-complete", currentCount: 15, maxCount: 100)
        try db.saveTask(source)

        // Linked NOT marked complete despite displayed ≥ maxCount (the inconsistent
        // state a sync conflict can produce); makeLinkedTask leaves completedAt nil.
        let linked = makeLinkedTask(
            id: "lnk-fc", sourceId: "src-first-complete",
            baseline: 0, maxCount: 10, isCompleted: false
        )
        try db.saveTask(linked)

        // Decrement to 12 — displayed=12 ≥ 10, so the linked first latches now.
        _ = try db.decrementSharedCounter(sourceTaskId: "src-first-complete", by: 3)

        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "lnk-fc") })
        XCTAssertTrue(fetched.isCompleted, "linked task should latch complete when displayed ≥ maxCount")
        XCTAssertNotNil(
            fetched.completedAt,
            "completedAt must be set when isCompleted first flips true (invariant: isCompleted ⟹ completedAt)"
        )
    }

    // MARK: - 4. affectedBoards

    /// An ACTIVE board that has a BoardTask placing the source task appears
    /// in `affectedBoards`. A board with no member-task placement does not.
    func test_affectedBoards_returnsActiveBoardsWithMemberTasks() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeSourceTask(id: "src-ab", currentCount: 5, maxCount: 20)
        try db.saveTask(source)

        let board = makeBoard(id: "board-a", name: "June Board")
        try db.saveBoard(board)

        let bt = makeBoardTask(boardId: "board-a", taskId: "src-ab")
        try db.saveBoardTask(bt)

        let result = try db.decrementSharedCounter(sourceTaskId: "src-ab", by: 2)

        XCTAssertEqual(result.effectiveDelta, 2)
        XCTAssertTrue(
            result.affectedBoards.contains(where: { $0.boardId == "board-a" }),
            "ACTIVE board containing the source task must appear in affectedBoards"
        )
    }

    /// Only ACTIVE boards appear in `affectedBoards`. A DRAFT board containing
    /// the same member task is excluded.
    func test_affectedBoards_excludesDraftBoards() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeSourceTask(id: "src-draft", currentCount: 5, maxCount: 20)
        try db.saveTask(source)

        // Build a DRAFT board by overriding the status field
        var draftBoardDict: [String: Any] = [
            "id": "board-draft",
            "userId": "u1",
            "name": "Draft Board",
            "status": BoardStatus.draft.rawValue,
            "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000",
            "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1,
            "isDeleted": false,
        ]
        let draftData = try JSONSerialization.data(withJSONObject: draftBoardDict)
        let draftBoard = try JSONDecoder().decode(Board.self, from: draftData)
        try db.saveBoard(draftBoard)

        let bt = makeBoardTask(boardId: "board-draft", taskId: "src-draft")
        try db.saveBoardTask(bt)

        let result = try db.decrementSharedCounter(sourceTaskId: "src-draft", by: 2)

        XCTAssertFalse(
            result.affectedBoards.contains(where: { $0.boardId == "board-draft" }),
            "DRAFT boards must NOT appear in affectedBoards"
        )
    }

    /// `affectedBoards` includes boards reached via LINKED tasks too, not just
    /// the source. A board with only a linked-task placement (no source placement)
    /// must still appear.
    func test_affectedBoards_includesBoardsWithLinkedTask() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeSourceTask(id: "src-linked-bd", currentCount: 5, maxCount: 20)
        try db.saveTask(source)

        let linked = makeLinkedTask(id: "lnk-bd", sourceId: "src-linked-bd", baseline: 0, maxCount: 10)
        try db.saveTask(linked)

        // Board has ONLY the linked task placed on it (not the source)
        let board = makeBoard(id: "board-linked-only", name: "Linked Board")
        try db.saveBoard(board)
        let bt = makeBoardTask(boardId: "board-linked-only", taskId: "lnk-bd")
        try db.saveBoardTask(bt)

        let result = try db.decrementSharedCounter(sourceTaskId: "src-linked-bd", by: 2)

        XCTAssertEqual(result.effectiveDelta, 2)
        XCTAssertTrue(
            result.affectedBoards.contains(where: { $0.boardId == "board-linked-only" }),
            "Boards containing LINKED member tasks must also appear in affectedBoards"
        )
    }

    // MARK: - Edge: passing a linked id (not source) throws

    func test_passingLinkedId_throws() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeSourceTask(id: "src-e", currentCount: 5, maxCount: 20)
        try db.saveTask(source)

        let linked = makeLinkedTask(id: "lnk-e", sourceId: "src-e")
        try db.saveTask(linked)

        XCTAssertThrowsError(
            try db.decrementSharedCounter(sourceTaskId: "lnk-e", by: 1),
            "Must throw when a derived (linked) task id is passed instead of the source"
        )
    }
}
