import XCTest
import GRDB
@testable import OYBC

/// Board Sources §Member rules B2 (iOS) — the *Deletion* half plus the three
/// readers that ride with it. Swift twin of
/// `apps/web/src/db/operations/__tests__/derivedCountersCascade.test.ts` (and
/// the `counterOps` / `repeatBoard` / `templateHealth` / `taskCountDisplay`
/// additions from the same web commit).
///
/// A window-stamped derived counter is a per-window artifact of the board it
/// was minted for: it is not library content the user authored, so when its
/// root is deleted (or the last board carrying it goes away) it must be
/// retired outright rather than unlinked and left behind as a mystery row.
/// These tests pin the write rulings the pure algorithms cannot express: every
/// tombstone bumps `version` AND enqueues its own sync item (a soft-delete
/// helper that forgets the enqueue resurrects the row on the next pull), the
/// placements/links go with the task, and RB5's "live placement" definition (a
/// live `board_tasks` row on a live board) decides whether a derived row
/// survives its board's deletion.
final class DerivedCountersCascadeTests: XCTestCase {

    // MARK: - Fixtures

    private let userId = "u1"
    private let root = "root-counter-1"
    private let now = "2026-09-18T10:00:00.000Z"
    private let windowStart = "2026-09-14T00:00:00.000Z"
    private let windowEnd = "2026-09-20T23:59:59.999Z"
    private let earlier = "2026-09-14T08:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let database = try AppDatabase.makeTestInstance()
        try database.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: earlier, updatedAt: earlier, lastSyncedAt: nil, version: 1
        ))
        return database
    }

    /// A stored row with all three `isWindowStampedDerived` marks.
    private func derivedCounter(
        id: String,
        rootId: String? = nil,
        startDate: String? = nil,
        createdInWizard: Bool = true,
        currentCount: Int = 0,
        isCompleted: Bool = false,
        version: Int = 1,
        isDeleted: Bool = false
    ) -> Task {
        Task(
            id: id, userId: userId, title: "Run 5 km", type: .counting,
            action: "Run", unit: "km", maxCount: 5,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, currentCount: currentCount,
            createdAt: earlier, updatedAt: earlier, version: version,
            isDeleted: isDeleted, deletedAt: isDeleted ? earlier : nil,
            timeframe: .weekly, startDate: startDate ?? windowStart, endDate: windowEnd,
            sharedCounterId: rootId ?? root, baseline: 0,
            createdInWizard: createdInWizard
        )
    }

    /// A per-window derived COMPOUND (no `sharedCounterId`; the other two marks).
    private func derivedCompound(
        id: String,
        startDate: String? = nil,
        createdInWizard: Bool = true
    ) -> Task {
        Task(
            id: id, userId: userId, title: "Strength circuit", type: .compound,
            operatorType: .and,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false,
            createdAt: earlier, updatedAt: earlier, version: 1, isDeleted: false,
            timeframe: .weekly, startDate: startDate ?? windowStart, endDate: windowEnd,
            createdInWizard: createdInWizard
        )
    }

    private func plainTask(id: String, type: TaskType = .normal) -> Task {
        Task(
            id: id, userId: userId, title: "Plain", type: type,
            operatorType: type == .compound ? .and : nil,
            totalCompletions: 0, totalInstances: 0, isCompleted: false,
            createdAt: earlier, updatedAt: earlier, version: 1, isDeleted: false
        )
    }

    private func makeBoard(
        id: String,
        isDeleted: Bool = false,
        startDate: String? = nil,
        timeframe: Timeframe = .weekly
    ) throws -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Week board",
            "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": timeframe.rawValue,
            "startDate": startDate ?? windowStart, "endDate": windowEnd,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": earlier, "updatedAt": earlier, "version": 1,
            "isDeleted": isDeleted,
        ]
        if isDeleted { dict["deletedAt"] = earlier }
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private var nextCell = 0

    private func placement(
        id: String,
        boardId: String,
        taskId: String,
        isDeleted: Bool = false,
        version: Int = 1
    ) -> BoardTask {
        nextCell += 1
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId,
            row: nextCell / 3, col: nextCell % 3, isCenter: false,
            createdAt: earlier, updatedAt: earlier, version: version,
            isDeleted: isDeleted, deletedAt: isDeleted ? earlier : nil
        )
    }

    private func link(id: String, compoundTaskId: String, childTaskId: String, index: Int = 0) -> CompoundChild {
        CompoundChild(
            id: id, compoundTaskId: compoundTaskId, childTaskId: childTaskId,
            childIndex: index, createdAt: earlier, updatedAt: earlier,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func queue(_ database: AppDatabase, _ entityType: String, _ entityId: String) throws -> [SyncQueueItem] {
        try database.read { db in
            try SyncQueueItem
                .filter(Column("entityType") == entityType && Column("entityId") == entityId)
                .fetchAll(db)
        }
    }

    private func task(_ database: AppDatabase, _ id: String) throws -> Task? {
        try database.read { try Task.fetchOne($0, key: id) }
    }

    private func boardTask(_ database: AppDatabase, _ id: String) throws -> BoardTask? {
        try database.read { try BoardTask.fetchOne($0, key: id) }
    }

    private func childLink(_ database: AppDatabase, _ id: String) throws -> CompoundChild? {
        try database.read { try CompoundChild.fetchOne($0, key: id) }
    }

    /// A derived counter's id IS `derivedTaskId(boardId, root)` — that is what
    /// makes it THIS board's artifact — so the board-deletion fixtures mint
    /// real ids rather than arbitrary ones.
    private func mintedCounter(boardId: String, rootId: String) -> Task {
        derivedCounter(
            id: BoardSources.derivedTaskId(boardId: boardId, rootTaskId: rootId),
            rootId: rootId
        )
    }

    @discardableResult
    private func runCascade(_ database: AppDatabase, _ ids: [String]) throws -> Int {
        try database.write { db in
            try AppDatabase.softDeleteWindowStampedDerived(db: db, taskIds: ids, now: self.now)
        }
    }

    // MARK: - softDeleteWindowStampedDerived

    func test_cascade_tombstonesTaskPlacementsAndLinks_eachVersionBumpedAndEnqueued() throws {
        let database = try makeDb()
        var derived = derivedCounter(id: "derived-1", version: 3)
        let board = try makeBoard(id: "board-1")
        let compound = derivedCompound(id: "compound-1")
        var bt = placement(id: "bt-1", boardId: board.id, taskId: derived.id, version: 2)
        try database.write { db in
            try board.insert(db)
            try derived.insert(db)
            try compound.insert(db)
            try bt.insert(db)
            try self.link(id: "link-1", compoundTaskId: compound.id, childTaskId: derived.id).insert(db)
        }

        XCTAssertEqual(try runCascade(database, [derived.id]), 1)

        derived = try XCTUnwrap(try task(database, "derived-1"))
        XCTAssertTrue(derived.isDeleted)
        XCTAssertEqual(derived.deletedAt, now)
        XCTAssertEqual(derived.updatedAt, now)
        XCTAssertEqual(derived.version, 4, "version + 1 from 3 — the LWW tie-break")
        let taskQueue = try queue(database, "tasks", derived.id)
        XCTAssertEqual(taskQueue.count, 1)
        XCTAssertEqual(taskQueue.first?.operationType, .delete)

        bt = try XCTUnwrap(try boardTask(database, "bt-1"))
        XCTAssertTrue(bt.isDeleted)
        XCTAssertEqual(bt.version, 3)
        XCTAssertEqual(try queue(database, "boardTasks", "bt-1").count, 1)

        let stored = try XCTUnwrap(try childLink(database, "link-1"))
        XCTAssertTrue(stored.isDeleted)
        XCTAssertEqual(stored.version, 2)
        XCTAssertEqual(try queue(database, "compoundChildren", "link-1").count, 1)
    }

    func test_cascade_tombstonesADerivedCompoundsOwnParentLinksButNotTheChildTask() throws {
        let database = try makeDb()
        let compound = derivedCompound(id: "compound-2")
        let child = derivedCounter(id: "derived-2")
        try database.write { db in
            try compound.insert(db)
            try child.insert(db)
            try self.link(id: "link-2", compoundTaskId: compound.id, childTaskId: child.id).insert(db)
        }

        try runCascade(database, [compound.id])

        XCTAssertTrue(try XCTUnwrap(try childLink(database, "link-2")).isDeleted)
        let survivor = try XCTUnwrap(try task(database, "derived-2"))
        XCTAssertFalse(survivor.isDeleted, "the child TASK is retired by its own entry, not its parent's")
        XCTAssertEqual(survivor.version, 1)
    }

    func test_cascade_isIdempotent_missingOrAlreadyTombstonedIdWritesNothing() throws {
        let database = try makeDb()
        let dead = derivedCounter(id: "derived-3", version: 9, isDeleted: true)
        try database.write { db in try dead.insert(db) }

        XCTAssertEqual(try runCascade(database, [dead.id, "no-such-task"]), 0)

        XCTAssertEqual(try XCTUnwrap(try task(database, "derived-3")).version, 9)
        XCTAssertEqual(try database.read { try SyncQueueItem.fetchCount($0) }, 0)
    }

    func test_windowStampedDerivedIdsForRoot_returnsOnlyLiveRowsCarryingAllThreeMarks() throws {
        let database = try makeDb()
        try database.write { db in
            try self.derivedCounter(id: "live-1").insert(db)
            try self.derivedCounter(id: "dead-1", isDeleted: true).insert(db)
            // A hand-made linked counter: shares the index, no window stamp.
            try self.derivedCounter(id: "handmade-1", createdInWizard: false).insert(db)
            // A window-stamped derived counter of a DIFFERENT root.
            try self.derivedCounter(id: "other-root-1", rootId: "root-counter-2").insert(db)
        }

        let ids = try database.read { db in
            try AppDatabase.windowStampedDerivedIdsForRoot(db: db, rootTaskId: self.root)
        }
        XCTAssertEqual(ids, ["live-1"])
    }

    // MARK: - (a) deleteTaskWithCascade — the root's derived members

    func test_rootDelete_retiresWindowStampedMembersAndLeavesTheOrdinaryOneAlone() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-a")
        let rootTask = plainTask(id: root, type: .counting)
        let derived = derivedCounter(id: "derived-a")
        let ordinary = derivedCounter(id: "ordinary-a", createdInWizard: false)
        let compound = derivedCompound(id: "compound-a")
        try database.write { db in
            try board.insert(db)
            try rootTask.insert(db)
            try derived.insert(db)
            try ordinary.insert(db)
            try compound.insert(db)
            try self.placement(id: "bt-a", boardId: board.id, taskId: derived.id).insert(db)
            try self.link(id: "link-a", compoundTaskId: compound.id, childTaskId: derived.id).insert(db)
        }

        try database.deleteTaskWithCascade(taskId: root)

        let retired = try XCTUnwrap(try task(database, "derived-a"))
        XCTAssertTrue(retired.isDeleted)
        XCTAssertEqual(retired.version, 2)
        XCTAssertEqual(try queue(database, "tasks", "derived-a").count, 1)
        XCTAssertTrue(try XCTUnwrap(try boardTask(database, "bt-a")).isDeleted)
        XCTAssertEqual(try queue(database, "boardTasks", "bt-a").count, 1)
        XCTAssertTrue(try XCTUnwrap(try childLink(database, "link-a")).isDeleted)
        XCTAssertEqual(try queue(database, "compoundChildren", "link-a").count, 1)

        let kept = try XCTUnwrap(try task(database, "ordinary-a"))
        XCTAssertFalse(kept.isDeleted, "an ordinary hub-derived member is unlinked elsewhere, never retired here")
        XCTAssertEqual(kept.version, 1)
        XCTAssertEqual(try queue(database, "tasks", "ordinary-a").count, 0)
    }

    func test_computeTaskDeletionImpact_splitsWindowStampedMembersFromOrdinaryOnes() throws {
        let database = try makeDb()
        try database.write { db in
            try self.plainTask(id: self.root, type: .counting).insert(db)
            try self.derivedCounter(id: "ordinary-b", createdInWizard: false).insert(db)
            try self.derivedCounter(id: "derived-b").insert(db)
        }

        let impact = try database.computeTaskDeletionImpact(taskId: root)

        XCTAssertEqual(impact.counterMemberCount, 1)
        XCTAssertEqual(impact.counterMembers.map { $0.id }, ["ordinary-b"])
        XCTAssertEqual(impact.derivedWindowCounterCount, 1)
    }

    func test_computeTaskDeletionImpact_reportsZeroDerivedWindowCountersForAPlainTask() throws {
        let database = try makeDb()
        try database.write { db in try self.plainTask(id: "solo").insert(db) }

        let impact = try database.computeTaskDeletionImpact(taskId: "solo")

        XCTAssertEqual(impact.derivedWindowCounterCount, 0)
        XCTAssertEqual(impact.counterMemberCount, 0)
    }

    // MARK: - (b) deleteCounterWithUnlink — the split

    func test_deleteCounterWithUnlink_retiresWindowStampedMembersAndUnlinksTheOrdinaryOne() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-b")
        // Root lifetime 40; the ordinary member's baseline 10 → keeps 30.
        var source = plainTask(id: root, type: .counting)
        source.currentCount = 40
        source.maxCount = 100
        source.isCounter = true
        var ordinary = derivedCounter(id: "ordinary-c", createdInWizard: false)
        ordinary.baseline = 10
        ordinary.maxCount = 50
        let windowed = derivedCounter(id: "windowed-c")
        try database.write { db in
            try board.insert(db)
            try source.insert(db)
            try ordinary.insert(db)
            try windowed.insert(db)
            try self.placement(id: "bt-c", boardId: board.id, taskId: windowed.id).insert(db)
        }

        try database.deleteCounterWithUnlink(sourceId: root, now: now)

        let retired = try XCTUnwrap(try task(database, "windowed-c"))
        XCTAssertTrue(retired.isDeleted)
        XCTAssertEqual(retired.version, 2)
        XCTAssertTrue(try XCTUnwrap(try boardTask(database, "bt-c")).isDeleted)
        // No carried-over snapshot event for a retired row.
        let events = try database.read { db in
            try TaskEvent.filter(Column("taskId") == "windowed-c").fetchCount(db)
        }
        XCTAssertEqual(events, 0)

        let unlinked = try XCTUnwrap(try task(database, "ordinary-c"))
        XCTAssertFalse(unlinked.isDeleted)
        XCTAssertNil(unlinked.sharedCounterId)
        XCTAssertNil(unlinked.baseline)
        XCTAssertEqual(unlinked.currentCount, 30, "40 − baseline 10, snapshotted at unlink")
    }

    // MARK: - (c) deleteBoard — RB5

    func test_boardDelete_retiresADerivedTaskPlacedOnlyOnTheDeletedBoard() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-d1")
        let derived = mintedCounter(boardId: board.id, rootId: root)
        try database.write { db in
            try board.insert(db)
            try derived.insert(db)
            try self.placement(id: "bt-d1", boardId: board.id, taskId: derived.id).insert(db)
        }

        try database.deleteBoard(id: board.id)

        XCTAssertTrue(try XCTUnwrap(try database.read { try Board.fetchOne($0, key: board.id) }).isDeleted)
        let retired = try XCTUnwrap(try task(database, derived.id))
        XCTAssertTrue(retired.isDeleted)
        XCTAssertEqual(retired.version, 2)
        XCTAssertEqual(try queue(database, "tasks", derived.id).count, 1)
        XCTAssertTrue(try XCTUnwrap(try boardTask(database, "bt-d1")).isDeleted)
    }

    func test_boardDelete_keepsADerivedTaskStillPlacedOnAnotherLiveBoard() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-d2")
        let other = try makeBoard(id: "board-d2-other")
        let derived = mintedCounter(boardId: board.id, rootId: root)
        try database.write { db in
            try board.insert(db)
            try other.insert(db)
            try derived.insert(db)
            try self.placement(id: "bt-d2", boardId: board.id, taskId: derived.id).insert(db)
            try self.placement(id: "bt-d2-other", boardId: other.id, taskId: derived.id).insert(db)
        }

        try database.deleteBoard(id: board.id)

        let kept = try XCTUnwrap(try task(database, derived.id))
        XCTAssertFalse(kept.isDeleted)
        XCTAssertEqual(kept.version, 1)
        XCTAssertFalse(try XCTUnwrap(try boardTask(database, "bt-d2-other")).isDeleted)
    }

    func test_boardDelete_cascadesWhenTheOnlyOtherPlacementSitsOnAnAlreadyDeletedBoard() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-d3")
        let deadBoard = try makeBoard(id: "board-d3-dead", isDeleted: true)
        let derived = mintedCounter(boardId: board.id, rootId: root)
        try database.write { db in
            try board.insert(db)
            try deadBoard.insert(db)
            try derived.insert(db)
            try self.placement(id: "bt-d3", boardId: board.id, taskId: derived.id).insert(db)
            try self.placement(id: "bt-d3-dead", boardId: deadBoard.id, taskId: derived.id).insert(db)
        }

        try database.deleteBoard(id: board.id)

        XCTAssertTrue(try XCTUnwrap(try task(database, derived.id)).isDeleted,
                      "a tombstoned board holds nothing alive")
    }

    func test_boardDelete_leavesOrdinaryLibraryTasksAndHandMadeLinkedCountersAlone() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-d4")
        try database.write { db in
            try board.insert(db)
            try self.plainTask(id: "plain-d4").insert(db)
            try self.derivedCounter(id: "handmade-d4", createdInWizard: false).insert(db)
            try self.placement(id: "bt-d4a", boardId: board.id, taskId: "plain-d4").insert(db)
            try self.placement(id: "bt-d4b", boardId: board.id, taskId: "handmade-d4").insert(db)
        }

        let orphaned = try database.read { db in
            try AppDatabase.windowStampedDerivedOrphanedByBoard(db: db, boardId: board.id)
        }
        XCTAssertEqual(orphaned, [])

        try database.deleteBoard(id: board.id)

        XCTAssertFalse(try XCTUnwrap(try task(database, "plain-d4")).isDeleted)
        XCTAssertFalse(try XCTUnwrap(try task(database, "handmade-d4")).isDeleted)
    }

    func test_boardDelete_retiresAPlacedDerivedCompoundItsLinksAndItsUnplacedDerivedParts() throws {
        // The One-square seam: a derived compound's parts have no placement of
        // their own, so nothing in `board_tasks` reaches them. Left behind,
        // each would be a per-window row with no board still collecting
        // baseline refreshes — and the root-delete path retires them, so the
        // two deletion paths would disagree.
        let database = try makeDb()
        let board = try makeBoard(id: "board-d5")
        let compound = derivedCompound(id: "compound-d5")
        let part = mintedCounter(boardId: board.id, rootId: root)
        try database.write { db in
            try board.insert(db)
            try compound.insert(db)
            try part.insert(db)
            // An ORIGINAL child (the user's own task, no window stamp).
            try self.plainTask(id: "original-d5").insert(db)
            try self.link(id: "link-d5a", compoundTaskId: compound.id, childTaskId: part.id).insert(db)
            try self.link(id: "link-d5b", compoundTaskId: compound.id, childTaskId: "original-d5", index: 1).insert(db)
            try self.placement(id: "bt-d5", boardId: board.id, taskId: compound.id).insert(db)
        }

        try database.deleteBoard(id: board.id)

        XCTAssertTrue(try XCTUnwrap(try task(database, compound.id)).isDeleted)
        XCTAssertTrue(try XCTUnwrap(try childLink(database, "link-d5a")).isDeleted)
        XCTAssertTrue(try XCTUnwrap(try childLink(database, "link-d5b")).isDeleted)

        let retiredPart = try XCTUnwrap(try task(database, part.id))
        XCTAssertTrue(retiredPart.isDeleted)
        XCTAssertEqual(retiredPart.version, 2)
        XCTAssertEqual(try queue(database, "tasks", part.id).count, 1)

        let original = try XCTUnwrap(try task(database, "original-d5"))
        XCTAssertFalse(original.isDeleted)
        XCTAssertEqual(original.version, 1)
        XCTAssertEqual(try queue(database, "tasks", "original-d5").count, 0)
    }

    func test_boardDelete_keepsADerivedPartAnotherLiveParentHoldsOrThatIsPlacedLive() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-d6")
        let other = try makeBoard(id: "board-d6-other")
        let compound = derivedCompound(id: "compound-d6")
        let partA = mintedCounter(boardId: board.id, rootId: root)
        let partB = mintedCounter(boardId: board.id, rootId: "root-counter-2")
        try database.write { db in
            try board.insert(db)
            try other.insert(db)
            try compound.insert(db)
            try partA.insert(db)
            try partB.insert(db)
            // A plain compound (no window stamp) that is NOT being retired.
            try self.plainTask(id: "plain-compound-d6", type: .compound).insert(db)
            try self.link(id: "link-d6a", compoundTaskId: compound.id, childTaskId: partA.id).insert(db)
            try self.link(id: "link-d6b", compoundTaskId: "plain-compound-d6", childTaskId: partA.id).insert(db)
            try self.link(id: "link-d6c", compoundTaskId: compound.id, childTaskId: partB.id, index: 1).insert(db)
            try self.placement(id: "bt-d6b", boardId: other.id, taskId: partB.id).insert(db)
            try self.placement(id: "bt-d6", boardId: board.id, taskId: compound.id).insert(db)
        }

        try database.deleteBoard(id: board.id)

        XCTAssertTrue(try XCTUnwrap(try task(database, compound.id)).isDeleted)
        XCTAssertFalse(try XCTUnwrap(try task(database, partA.id)).isDeleted,
                       "another live parent link still holds part A")
        XCTAssertFalse(try XCTUnwrap(try childLink(database, "link-d6b")).isDeleted)
        XCTAssertFalse(try XCTUnwrap(try task(database, partB.id)).isDeleted,
                       "part B has its own live placement on a live board")
        XCTAssertFalse(try XCTUnwrap(try boardTask(database, "bt-d6b")).isDeleted)
    }

    func test_boardDelete_keepsADerivedCompoundStillPlacedOnAnotherLiveBoard() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-d7")
        let other = try makeBoard(id: "board-d7-other")
        let compound = derivedCompound(id: "compound-d7")
        let part = mintedCounter(boardId: board.id, rootId: root)
        try database.write { db in
            try board.insert(db)
            try other.insert(db)
            try compound.insert(db)
            try part.insert(db)
            try self.link(id: "link-d7", compoundTaskId: compound.id, childTaskId: part.id).insert(db)
            try self.placement(id: "bt-d7", boardId: board.id, taskId: compound.id).insert(db)
            try self.placement(id: "bt-d7-other", boardId: other.id, taskId: compound.id).insert(db)
        }

        try database.deleteBoard(id: board.id)

        XCTAssertFalse(try XCTUnwrap(try task(database, compound.id)).isDeleted)
        XCTAssertFalse(try XCTUnwrap(try task(database, part.id)).isDeleted)
        XCTAssertFalse(try XCTUnwrap(try childLink(database, "link-d7")).isDeleted)
    }

    func test_orphanSweep_isOrderIndependentOfTheBoardsOwnPlacementTombstoning() throws {
        // `deleteBoard` does not tombstone its own placements today. If it
        // ever does, this sweep must not care where in the sequence it runs —
        // a live-only candidate query would quietly find nothing and retire
        // nothing, which no other test here would catch.
        let database = try makeDb()
        let board = try makeBoard(id: "board-d8")
        let derived = mintedCounter(boardId: board.id, rootId: root)
        let compound = derivedCompound(id: "compound-d8")
        let part = mintedCounter(boardId: board.id, rootId: "root-counter-3")
        try database.write { db in
            try board.insert(db)
            try derived.insert(db)
            try compound.insert(db)
            try part.insert(db)
            try self.link(id: "link-d8", compoundTaskId: compound.id, childTaskId: part.id).insert(db)
            try self.placement(id: "bt-d8a", boardId: board.id, taskId: derived.id).insert(db)
            try self.placement(id: "bt-d8b", boardId: board.id, taskId: compound.id).insert(db)
        }

        let before = try database.read { db in
            try AppDatabase.windowStampedDerivedOrphanedByBoard(db: db, boardId: board.id)
        }.sorted()

        try database.write { db in
            for id in ["bt-d8a", "bt-d8b"] {
                var bt = try XCTUnwrap(try BoardTask.fetchOne(db, key: id))
                bt.isDeleted = true
                bt.deletedAt = self.now
                try bt.update(db)
            }
        }
        let after = try database.read { db in
            try AppDatabase.windowStampedDerivedOrphanedByBoard(db: db, boardId: board.id)
        }.sorted()

        XCTAssertEqual(before, [derived.id, compound.id, part.id].sorted())
        XCTAssertEqual(after, before)
    }

    func test_boardDelete_doesNotCascadeARowMintedForAnotherBoardThatOnlyLeftAStalePlacementHere() throws {
        // Board Edit's cell removal tombstones a single placement. A derived
        // counter minted for board TWO that once passed through board ONE is
        // board TWO's artifact: its id encodes TWO, and ONE's deletion has no
        // claim on it — even though it is currently placed nowhere live.
        let database = try makeDb()
        let one = try makeBoard(id: "board-d9-one")
        let two = try makeBoard(id: "board-d9-two")
        let foreign = mintedCounter(boardId: two.id, rootId: root)
        try database.write { db in
            try one.insert(db)
            try two.insert(db)
            try foreign.insert(db)
            try self.placement(id: "bt-d9", boardId: one.id, taskId: foreign.id, isDeleted: true).insert(db)
        }

        let orphaned = try database.read { db in
            try AppDatabase.windowStampedDerivedOrphanedByBoard(db: db, boardId: one.id)
        }
        XCTAssertEqual(orphaned, [])

        try database.deleteBoard(id: one.id)

        let kept = try XCTUnwrap(try task(database, foreign.id))
        XCTAssertFalse(kept.isDeleted)
        XCTAssertEqual(kept.version, 1)
        XCTAssertEqual(try queue(database, "tasks", foreign.id).count, 0)
    }

    func test_boardDelete_doesCascadeARowMintedForThisBoardThatWasSwappedOutOfIt() throws {
        // Same stale-placement shape, opposite provenance: this row was minted
        // for the board being deleted, so it can never legitimately belong to
        // another board — a swap-out left it dangling, and the deletion
        // collects it.
        let database = try makeDb()
        let board = try makeBoard(id: "board-d10")
        let swappedOut = mintedCounter(boardId: board.id, rootId: root)
        try database.write { db in
            try board.insert(db)
            try swappedOut.insert(db)
            try self.placement(id: "bt-d10", boardId: board.id, taskId: swappedOut.id, isDeleted: true).insert(db)
        }

        let orphaned = try database.read { db in
            try AppDatabase.windowStampedDerivedOrphanedByBoard(db: db, boardId: board.id)
        }
        XCTAssertEqual(orphaned, [swappedOut.id])

        try database.deleteBoard(id: board.id)

        let retired = try XCTUnwrap(try task(database, swappedOut.id))
        XCTAssertTrue(retired.isDeleted)
        XCTAssertEqual(retired.version, 2)
        XCTAssertEqual(try queue(database, "tasks", swappedOut.id).count, 1)
    }

    func test_boardDelete_doesNotCascadeADerivedCompoundStampedForADifferentWindow() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-d11")
        // Same board, different window — last window's compound, whatever left
        // the stale placement behind.
        let stale = derivedCompound(id: "compound-d11", startDate: "2026-09-07T00:00:00.000Z")
        let thisWindowsPart = mintedCounter(boardId: board.id, rootId: root)
        try database.write { db in
            try board.insert(db)
            try stale.insert(db)
            try thisWindowsPart.insert(db)
            try self.link(id: "link-d11", compoundTaskId: stale.id, childTaskId: thisWindowsPart.id).insert(db)
            try self.placement(id: "bt-d11", boardId: board.id, taskId: stale.id, isDeleted: true).insert(db)
        }

        try database.deleteBoard(id: board.id)

        XCTAssertFalse(try XCTUnwrap(try task(database, stale.id)).isDeleted)
    }

    // MARK: - (d) repeatBoardAsTemplate — RB4

    func test_repeatBoard_dropsDerivedCompoundsRecordsDerivedCountersByTheirRootAndAuthorsEmptySourcesAndVary() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-r1")
        let derivedCompoundRow = derivedCompound(id: "compound-r1")
        let derivedCounterRow = derivedCounter(id: "derived-r1")
        try database.write { db in
            try board.insert(db)
            try self.plainTask(id: "plain-r1").insert(db)
            // The derived counter’s durable root — what the record must name.
            try self.plainTask(id: self.root, type: .counting).insert(db)
            try derivedCompoundRow.insert(db)
            try derivedCounterRow.insert(db)
            // A hand-made COMPOUND with no window stamp stays a member.
            try self.plainTask(id: "plain-compound-r1", type: .compound).insert(db)
            try self.placement(id: "bt-r1a", boardId: board.id, taskId: "plain-r1").insert(db)
            try self.placement(id: "bt-r1b", boardId: board.id, taskId: "compound-r1").insert(db)
            try self.placement(id: "bt-r1c", boardId: board.id, taskId: "derived-r1").insert(db)
            try self.placement(id: "bt-r1d", boardId: board.id, taskId: "plain-compound-r1").insert(db)
        }

        let template = try XCTUnwrap(try database.repeatBoardAsTemplate(
            board: board, cadence: .weekly, userId: userId, weekStartDay: "monday", now: now
        ))

        XCTAssertEqual(template.sources, [])
        XCTAssertEqual(template.manualTaskVary, [:])
        let members = template.manualTaskIds ?? []
        XCTAssertFalse(members.contains("compound-r1"), "a per-window derived compound does not carry forward")
        XCTAssertFalse(members.contains("derived-r1"), "the per-window derived row is never named")
        XCTAssertTrue(members.contains(root), "a derived counter is recorded by its durable ROOT")
        XCTAssertTrue(members.contains("plain-r1"))
        XCTAssertTrue(members.contains("plain-compound-r1"))

        let stored = try XCTUnwrap(try database.fetchRecurringBoardTemplate(id: template.id))
        XCTAssertEqual(stored.sources, [])
        XCTAssertEqual(stored.manualTaskVary, [:])
        XCTAssertFalse((stored.manualTaskIds ?? []).contains("compound-r1"))
    }

    func test_repeatBoard_recordSurvivesDeletingTheBoardItWasRepeatedFrom() throws {
        // Final-review FI2 — before the amendment the record named the DERIVED
        // id, the board delete retired that row, and validateSpawnPool then
        // skipped every future window as .hasDeletedTasks.
        let database = try makeDb()
        let board = try makeBoard(id: "board-r2")
        let derivedRow = derivedCounter(
            id: BoardSources.derivedTaskId(boardId: "board-r2", rootTaskId: root)
        )
        try database.write { db in
            try board.insert(db)
            try self.plainTask(id: self.root, type: .counting).insert(db)
            try derivedRow.insert(db)
            try self.placement(id: "bt-r2a", boardId: board.id, taskId: derivedRow.id).insert(db)
            // Fill the other 8 cells so pool size is never the complaint
            // (a 3x3 with centerSquareType .none wants 9 members).
            for index in 0..<8 {
                try self.plainTask(id: "filler-r2-\(index)").insert(db)
                try self.placement(
                    id: "bt-r2-\(index)", boardId: board.id, taskId: "filler-r2-\(index)"
                ).insert(db)
            }
        }

        let template = try XCTUnwrap(try database.repeatBoardAsTemplate(
            board: board, cadence: .weekly, userId: userId, weekStartDay: "monday", now: now
        ))
        XCTAssertTrue((template.manualTaskIds ?? []).contains(root))
        XCTAssertFalse((template.manualTaskIds ?? []).contains(derivedRow.id))

        try database.deleteBoard(id: board.id)

        XCTAssertTrue(try XCTUnwrap(try task(database, derivedRow.id)).isDeleted,
                      "the derived row still dies with its board (RB5)")
        let stored = try XCTUnwrap(try database.fetchRecurringBoardTemplate(id: template.id))
        let poolTasks = try database.read { db in
            try Task.filter((stored.manualTaskIds ?? []).contains(Column("id"))).fetchAll(db)
        }
        XCTAssertEqual(poolTasks.count, 9)
        XCTAssertFalse(poolTasks.contains { $0.isDeleted })
        XCTAssertEqual(validateSpawnPool(template: stored, poolTasks: poolTasks), .ok)
    }

    func test_repeatBoard_skipsADerivedCounterWhoseRootIsGone() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-r3")
        var deadRoot = plainTask(id: root, type: .counting)
        deadRoot.isDeleted = true
        deadRoot.deletedAt = earlier
        try database.write { db in
            try board.insert(db)
            try deadRoot.insert(db)
            try self.plainTask(id: "plain-r3").insert(db)
            try self.derivedCounter(id: "derived-r3").insert(db)
            try self.placement(id: "bt-r3a", boardId: board.id, taskId: "plain-r3").insert(db)
            try self.placement(id: "bt-r3b", boardId: board.id, taskId: "derived-r3").insert(db)
        }

        let template = try XCTUnwrap(try database.repeatBoardAsTemplate(
            board: board, cadence: .weekly, userId: userId, weekStartDay: "monday", now: now
        ))

        XCTAssertEqual(template.manualTaskIds ?? [], ["plain-r3"])
    }

    // MARK: - (e) roster health — Split-up expansion

    func test_rosterHealth_aSplitUpMemberRuleExpandsTheCompoundBeforeTheCount() throws {
        // The roster count must be the honest one: a compound member the user
        // set to "Split up" contributes its parts, so a 7-member supply with a
        // 3-part compound is 9 squares, not 7 — the same expansion a new
        // window's assembly performs.
        let plainIds = (1...6).map { "plain-\($0)" }
        let partIds = ["part-1", "part-2", "part-3"]
        var tasksById: [String: Task] = [:]
        for id in plainIds + partIds { tasksById[id] = plainTask(id: id) }
        tasksById["c1"] = plainTask(id: "c1", type: .compound)

        let source = BoardSource(
            sourceId: "p1", kind: .pool, min: 0, max: nil,
            excludedTaskIds: [], filter: .all,
            memberRules: ["c1": BoardSourceMemberRule(split: true)]
        )
        let template = RecurringBoardTemplate(
            id: "tpl-1", userId: userId, name: "Weekly", timeframe: .weekly,
            boardSize: 3, centerSquareType: .none, isRandomized: false,
            seedTaskIds: [], poolIds: [], manualTaskIds: [], removedTaskIds: [],
            sources: [source], manualTaskVary: [:],
            isActive: true, createdAt: now, updatedAt: now, version: 1
        )
        let links = partIds.enumerated().map { index, childId in
            link(id: "l-\(index)", compoundTaskId: "c1", childTaskId: childId, index: index)
        }
        let resolution = RecurringBoardTemplatesViewModel.TemplateSupplyResolution(
            supplies: [BoardSources.Supply(source: source, supplyTaskIds: ["c1"] + plainIds)],
            deadBoardSourceIds: [],
            manualTaskIds: [],
            childrenByCompoundId: ["c1": links]
        )

        let health = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [template],
            resolutionByTemplateId: ["tpl-1": resolution],
            tasksById: tasksById
        )

        let mix = try XCTUnwrap(health.mixByTemplateId["tpl-1"])
        XCTAssertFalse(mix.contains("c1"), "the split member itself never reaches the board")
        for partId in partIds { XCTAssertTrue(mix.contains(partId), "\(partId) must be in the mix") }
        XCTAssertEqual(mix.count, 9, "3 parts + 6 plain members = a full 3x3")
        XCTAssertNil(health.attentionByTemplateId["tpl-1"])
    }

    func test_rosterHealth_withoutASplitRuleTheCompoundCountsAsOneSquare() throws {
        // The non-degenerate control for the test above: same supply, no rule.
        let plainIds = (1...6).map { "plain-\($0)" }
        var tasksById: [String: Task] = [:]
        for id in plainIds + ["part-1", "part-2", "part-3"] { tasksById[id] = plainTask(id: id) }
        tasksById["c1"] = plainTask(id: "c1", type: .compound)

        let source = BoardSource(
            sourceId: "p1", kind: .pool, min: 0, max: nil,
            excludedTaskIds: [], filter: .all, memberRules: [:]
        )
        let template = RecurringBoardTemplate(
            id: "tpl-2", userId: userId, name: "Weekly", timeframe: .weekly,
            boardSize: 3, centerSquareType: .none, isRandomized: false,
            seedTaskIds: [], poolIds: [], manualTaskIds: [], removedTaskIds: [],
            sources: [source], manualTaskVary: [:],
            isActive: true, createdAt: now, updatedAt: now, version: 1
        )
        let links = ["part-1", "part-2", "part-3"].enumerated().map { index, childId in
            link(id: "l2-\(index)", compoundTaskId: "c1", childTaskId: childId, index: index)
        }
        let resolution = RecurringBoardTemplatesViewModel.TemplateSupplyResolution(
            supplies: [BoardSources.Supply(source: source, supplyTaskIds: ["c1"] + plainIds)],
            deadBoardSourceIds: [],
            manualTaskIds: [],
            childrenByCompoundId: ["c1": links]
        )

        let health = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [template],
            resolutionByTemplateId: ["tpl-2": resolution],
            tasksById: tasksById
        )

        let mix = try XCTUnwrap(health.mixByTemplateId["tpl-2"])
        XCTAssertTrue(mix.contains("c1"))
        XCTAssertEqual(mix.count, 7, "the compound is ONE square without a Split-up rule")
        XCTAssertEqual(health.attentionByTemplateId["tpl-2"], .poolTooSmall,
                       "7 squares cannot fill a 3x3 — the honest badge")
    }

    // MARK: - (f) read audit — RB7

    private func countingTask(
        id: String,
        sharedCounterId: String? = nil,
        baseline: Int? = nil,
        maxCount: Int?,
        currentCount: Int,
        isCompleted: Bool = false
    ) -> Task {
        Task(
            id: id, userId: userId, title: "Run", type: .counting,
            action: "Run", unit: "km", maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, currentCount: currentCount,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId, baseline: baseline
        )
    }

    func test_displayedCount_baselineAdjustsALinkedTaskAndReadsARootRaw() {
        // The root at 12, a window that opened at 10, a personal goal of 5.
        let linked = countingTask(id: "linked", sharedCounterId: "root-1",
                                  baseline: 10, maxCount: 5, currentCount: 12)
        XCTAssertEqual(TaskCountDisplay.displayedCount(for: linked), 2)

        let rootTask = countingTask(id: "root", maxCount: 20, currentCount: 12)
        XCTAssertEqual(TaskCountDisplay.displayedCount(for: rootTask), 12)
    }

    func test_displayedCount_clampsBelowTheBaselineToZeroAndNeverClampsOvershoot() {
        let under = countingTask(id: "under", sharedCounterId: "r", baseline: 20,
                                 maxCount: 5, currentCount: 5)
        XCTAssertEqual(TaskCountDisplay.displayedCount(for: under), 0)

        let over = countingTask(id: "over", sharedCounterId: "r", baseline: 0,
                                maxCount: 5, currentCount: 9)
        XCTAssertEqual(TaskCountDisplay.displayedCount(for: over), 9,
                       "overshoot past the goal is real progress — never clamped")
    }

    func test_isInProgress_measuresALinkedMemberAgainstItsOwnBaseline() {
        let library = TaskLibraryViewModel()
        // The root has run to 12, but this member's window opened at 12 too:
        // displayed 0, so the member has not started. Reading `currentCount`
        // raw would call it in progress the moment its window opened.
        let fresh = countingTask(id: "fresh", sharedCounterId: "root-1",
                                 baseline: 12, maxCount: 5, currentCount: 12)
        XCTAssertFalse(TasksTabViewModel.isInProgress(fresh, library: library))

        let started = countingTask(id: "started", sharedCounterId: "root-1",
                                   baseline: 10, maxCount: 5, currentCount: 12)
        XCTAssertTrue(TasksTabViewModel.isInProgress(started, library: library))

        let rootTask = countingTask(id: "root", maxCount: 20, currentCount: 12)
        XCTAssertTrue(TasksTabViewModel.isInProgress(rootTask, library: library))
    }

    // MARK: - (g) affected-board folds (final-review items 7 + 10)

    /// A 3×3 board whose row 0 is persisted as a completed bingo line.
    private func boardWithCompletedRow0(
        _ database: AppDatabase,
        id: String,
        taskIds: [String]
    ) throws -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Week board",
            "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": Timeframe.weekly.rawValue,
            "startDate": windowStart, "endDate": windowEnd,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 3, "linesCompleted": 1,
            "completedLineIds": "[\"row_0\"]",
            "createdAt": earlier, "updatedAt": earlier, "version": 1,
            "isDeleted": false,
        ]
        let board = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
        try database.write { db in
            try board.insert(db)
            for (col, taskId) in taskIds.enumerated() {
                try BoardTask(
                    id: "bt-\(id)-\(col)", boardId: id, taskId: taskId,
                    row: 0, col: col, isCenter: false,
                    createdAt: self.earlier, updatedAt: self.earlier, version: 1,
                    isDeleted: false, deletedAt: nil
                ).insert(db)
            }
        }
        return board
    }

    /// A normal task completed INSIDE the board's window (event-owning, so it
    /// needs a real completion event to read complete).
    private func windowedCompleteTask(_ database: AppDatabase, id: String) throws {
        try database.write { db in
            var t = self.plainTask(id: id)
            t.isCompleted = true
            t.completedAt = self.earlier
            try t.insert(db)
            try TaskEvent(
                id: "ev-\(id)", userId: self.userId, taskId: id,
                kind: .completion, delta: nil, occurredAt: self.earlier, boardId: nil,
                createdAt: self.earlier, updatedAt: self.earlier,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).insert(db)
        }
    }

    func test_rootDelete_reDerivesTheBoardThatCarriedTheRetiredDerivedCounter() throws {
        // Item 7 — the step-4b affected-board fold. Deleting the fold leaves
        // the board's persisted bingo line glowing through a retired cell.
        let database = try makeDb()
        var source = plainTask(id: root, type: .counting)
        source.isCounter = true
        var derived = derivedCounter(id: "derived-g1")
        derived.isCompleted = true
        derived.completedAt = earlier
        try database.write { db in
            try source.insert(db)
            try derived.insert(db)
        }
        try windowedCompleteTask(database, id: "plain-g1")
        try windowedCompleteTask(database, id: "plain-g2")
        let board = try boardWithCompletedRow0(
            database, id: "board-g1", taskIds: ["derived-g1", "plain-g1", "plain-g2"]
        )

        try database.deleteTaskWithCascade(taskId: root)

        let after = try XCTUnwrap(try database.fetchBoard(id: board.id))
        XCTAssertFalse((after.completedLineIds ?? []).contains("row_0"),
                       "a bingo line cannot keep glowing through a retired cell")
        XCTAssertEqual(after.completedTasks, 2)
        XCTAssertGreaterThan(after.version, 1, "the board was in the affected set")
    }

    func test_rootDelete_leavesABoardOfOnlyOrdinaryTasksOutOfTheAffectedSet() throws {
        // The control: a board the deleted root never reached must NOT be
        // touched, or the fold above would be proving nothing.
        let database = try makeDb()
        var source = plainTask(id: root, type: .counting)
        source.isCounter = true
        try database.write { db in
            try source.insert(db)
            try self.derivedCounter(id: "derived-g2").insert(db)
        }
        try windowedCompleteTask(database, id: "plain-g3")
        try windowedCompleteTask(database, id: "plain-g4")
        try windowedCompleteTask(database, id: "plain-g5")
        let untouched = try boardWithCompletedRow0(
            database, id: "board-g2", taskIds: ["plain-g3", "plain-g4", "plain-g5"]
        )

        try database.deleteTaskWithCascade(taskId: root)

        let after = try XCTUnwrap(try database.fetchBoard(id: untouched.id))
        XCTAssertEqual(after.version, 1, "an unrelated board never joins the affected set")
    }

    func test_deleteCounterWithUnlink_reDerivesTheBoardsOfTheMembersItRetires() throws {
        // Item 10 — the hub path retires the window-stamped members ITSELF,
        // before the cascade, so the cascade's own step-4b lookup finds
        // nothing left to fold. Without the caller handing those boards over
        // the line below would keep glowing.
        let database = try makeDb()
        var source = plainTask(id: root, type: .counting)
        source.currentCount = 40
        source.maxCount = 100
        source.isCounter = true
        var derived = derivedCounter(id: "derived-g3")
        derived.isCompleted = true
        derived.completedAt = earlier
        try database.write { db in
            try source.insert(db)
            try derived.insert(db)
        }
        try windowedCompleteTask(database, id: "plain-g6")
        try windowedCompleteTask(database, id: "plain-g7")
        let board = try boardWithCompletedRow0(
            database, id: "board-g3", taskIds: ["derived-g3", "plain-g6", "plain-g7"]
        )

        try database.deleteCounterWithUnlink(sourceId: root, now: now)

        XCTAssertTrue(try XCTUnwrap(try task(database, "derived-g3")).isDeleted)
        let after = try XCTUnwrap(try database.fetchBoard(id: board.id))
        XCTAssertFalse((after.completedLineIds ?? []).contains("row_0"))
        XCTAssertEqual(after.completedTasks, 2)
        XCTAssertGreaterThan(after.version, 1, "the retired member's board re-derived in-txn")
    }

    // MARK: - (h) read audit — the count STRING (final-review item 9)

    func test_countingSubtitle_readsTheLinkedMembersOwnNumberNotTheRootMirror() {
        // A member of a root at 12 whose window opened at 10, goal 5.
        let linked = countingTask(id: "linked-h", sharedCounterId: "root-1",
                                  baseline: 10, maxCount: 5, currentCount: 12)
        XCTAssertEqual(TaskCountDisplay.countingSubtitle(for: linked), "Run · 2 / 5 km")

        let rootTask = countingTask(id: "root-h", maxCount: 20, currentCount: 12)
        XCTAssertEqual(TaskCountDisplay.countingSubtitle(for: rootTask), "Run · 12 / 20 km")
    }

    func test_countingSubtitle_isNilWhenTheTaskCannotFormOne() {
        let goalless = countingTask(id: "goalless-h", maxCount: nil, currentCount: 3)
        XCTAssertNil(TaskCountDisplay.countingSubtitle(for: goalless))
    }
}
