import XCTest
import GRDB
@testable import OYBC

/// docs/GUEST_MODE.md §Collision — every sync-queue item is stamped with the
/// uid signed in at enqueue (`ownerUid`, a LOCAL column added in v33), and the
/// push path (`SyncService.pushSyncCore`) runs the fetched PENDING list through
/// `AppDatabase.dropForeignOwnedSyncItems` before its per-item loop: an item
/// owned by another uid is DROPPED (never pushed), so a discarded guest's
/// `boardTasks`/`compoundChildren` can't be accepted into the real account
/// during the switch race. Legacy nil-owner rows push as before.
///
/// Web twin: `apps/web/src/firebase/__tests__/syncQueueOwnership.test.ts`.
final class SyncQueueOwnershipTests: XCTestCase {

    private let anon = "anon-uid"
    private let real = "real-uid"

    override func tearDown() {
        SyncQueueOwnership.provider = { nil }
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Enqueue a `boardTasks` op (no `userId` in the payload — the rules can't
    /// catch a cross-account push) as whoever `signedIn` is.
    private func enqueuePlacement(
        _ db: AppDatabase,
        entityId: String = "bt1",
        op: SyncOperationType = .create,
        signedIn uid: String?
    ) throws {
        SyncQueueOwnership.provider = { uid }
        try db.write { grdb in
            try SyncQueueBuilder.makeItem(
                entityType: "boardTasks",
                entityId: entityId,
                operationType: op,
                payload: ["id": entityId, "boardId": "b1"],
                now: AppDatabase.currentTimestamp()
            ).enqueue(grdb)
        }
    }

    /// What the push loop would iterate for `userId`: the same two calls
    /// `pushSyncCore` makes.
    private func itemsPushedAs(_ userId: String, _ db: AppDatabase) throws -> [SyncQueueItem] {
        try db.dropForeignOwnedSyncItems(db.fetchPendingSyncItems(), userId: userId)
    }

    private func queueCount(_ db: AppDatabase) throws -> Int {
        try db.read { try SyncQueueItem.fetchCount($0) }
    }

    // MARK: - Stamping

    func test_enqueue_stampsSignedInUid() throws {
        let db = try AppDatabase.makeTestInstance()
        try enqueuePlacement(db, signedIn: anon)

        let rows = try db.read { try SyncQueueItem.fetchAll($0) }
        XCTAssertEqual(rows.map(\.ownerUid), [anon])
    }

    // MARK: - Push filter (the three cases)

    func test_itemQueuedUnderA_isDroppedNotPushed_whenPushingAsB() throws {
        let db = try AppDatabase.makeTestInstance()
        try enqueuePlacement(db, signedIn: anon)

        // The collision switch: now signed in as the real account.
        let pushed = try itemsPushedAs(real, db)

        XCTAssertTrue(pushed.isEmpty, "a foreign-owned item must never reach the push loop")
        XCTAssertEqual(try queueCount(db), 0, "a foreign-owned item is dropped from the queue")
    }

    func test_itemQueuedUnderPushingUid_isPushed() throws {
        let db = try AppDatabase.makeTestInstance()
        try enqueuePlacement(db, signedIn: real)

        let pushed = try itemsPushedAs(real, db)

        XCTAssertEqual(pushed.map(\.entityId), ["bt1"])
        XCTAssertEqual(try queueCount(db), 1)
    }

    func test_legacyUnstampedItem_isPushed() throws {
        let db = try AppDatabase.makeTestInstance()
        try enqueuePlacement(db, signedIn: nil)
        XCTAssertNil(try db.read { try SyncQueueItem.fetchOne($0) }?.ownerUid)

        let pushed = try itemsPushedAs(real, db)

        XCTAssertEqual(pushed.map(\.entityId), ["bt1"])
        XCTAssertEqual(try queueCount(db), 1)
    }

    // MARK: - Coalescing stays within one owner

    func test_newOwnersEdit_neverCoalescesIntoAnotherOwnersRow() throws {
        let db = try AppDatabase.makeTestInstance()
        try enqueuePlacement(db, op: .create, signedIn: anon)
        try enqueuePlacement(db, op: .update, signedIn: real)

        let owners = try db.read { try SyncQueueItem.fetchAll($0) }.compactMap(\.ownerUid).sorted()
        XCTAssertEqual(owners, [anon, real])

        // Only the real account's row survives the push filter.
        let pushed = try itemsPushedAs(real, db)
        XCTAssertEqual(pushed.map(\.ownerUid), [real])
    }

    func test_legacyRow_isAdoptedAndRestampedByStampedOp() throws {
        let db = try AppDatabase.makeTestInstance()
        try enqueuePlacement(db, op: .create, signedIn: nil)
        try enqueuePlacement(db, op: .update, signedIn: real)

        let rows = try db.read { try SyncQueueItem.fetchAll($0) }
        XCTAssertEqual(rows.count, 1, "a legacy row coalesces as before")
        XCTAssertEqual(rows.first?.ownerUid, real)
    }

    // MARK: - Pure predicates (twin of the shared TS truth table)

    func test_predicates_matchSharedTruthTable() {
        XCTAssertTrue(SyncQueueOwnership.isForeign(ownerUid: "a", userId: "b"))
        XCTAssertFalse(SyncQueueOwnership.isForeign(ownerUid: "a", userId: "a"))
        XCTAssertFalse(SyncQueueOwnership.isForeign(ownerUid: nil, userId: "a"))

        XCTAssertTrue(SyncQueueOwnership.canCoalesce(existing: "a", incoming: "a"))
        XCTAssertFalse(SyncQueueOwnership.canCoalesce(existing: "a", incoming: "b"))
        XCTAssertFalse(SyncQueueOwnership.canCoalesce(existing: "a", incoming: nil))
        XCTAssertTrue(SyncQueueOwnership.canCoalesce(existing: nil, incoming: "a"))
        XCTAssertTrue(SyncQueueOwnership.canCoalesce(existing: nil, incoming: nil))
    }
}
