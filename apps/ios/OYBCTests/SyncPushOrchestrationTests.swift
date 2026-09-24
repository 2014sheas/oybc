import XCTest
import GRDB
@testable import OYBC

/// Push orchestration (read remote → LWW → write → mark completed), driven
/// through the injectable `FirestoreDocStore` seam against an in-memory
/// `AppDatabase.makeTestInstance()` — no Firebase session, no network.
///
/// Pins the four LWW outcomes of `SyncService.processPushItem`. Remote-wins on
/// the PUSH path overwrites the local row with the remote doc and completes the
/// item — it does NOT re-enqueue (the BOARD_INTEGRITY PR-4 re-assert is a
/// PULL-path local-wins behaviour, `reassertLocalWinIfNeeded`).
/// Web twin: `apps/web/src/firebase/__tests__/syncPushOrchestration.test.ts`.
@MainActor
final class SyncPushOrchestrationTests: XCTestCase {

    // MARK: - Fake store

    /// In-memory `FirestoreDocStore`: a path → doc map plus a write log.
    private final class FakeDocStore: FirestoreDocStore {
        var docs: [String: [String: Any]] = [:]
        var writes: [(path: String, data: [String: Any])] = []
        var writeError: Error?

        func fetch(path: String) async throws -> [String: Any]? { docs[path] }

        func write(path: String, data: [String: Any]) async throws {
            if let writeError { throw writeError }
            writes.append((path, data))
        }
    }

    private struct FakeWriteError: LocalizedError {
        var errorDescription: String? { "unavailable: offline" }
    }

    // MARK: - Fixtures

    private let userId = "me"
    private let taskId = "task-1"
    private var path: String { "users/\(userId)/tasks/\(taskId)" }

    private func makeTask(version: Int, updatedAt: String, title: String) -> Task {
        Task(
            id: taskId, userId: userId, title: title, description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil,
            requiredCount: nil, totalCompletions: 0, totalInstances: 0, isCompleted: false,
            completedAt: nil, currentCount: nil, createdAt: "2026-09-01T00:00:00.000Z",
            updatedAt: updatedAt, lastSyncedAt: nil, version: version, isDeleted: false,
            deletedAt: nil, timeframe: nil, startDate: nil, endDate: nil, sharedCounterId: nil,
            baseline: nil, lastSyncedCount: nil, createdInWizard: false, isCounter: false
        )
    }

    /// The remote doc as Firestore would hand it back: the task's JSON shape.
    private func remoteDoc(_ task: Task) throws -> [String: Any] {
        let data = SyncQueueBuilder.encodePayload(task).data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// Saves `local` (plus its owning user row — `tasks.userId` is a foreign
    /// key) and enqueues its UPDATE, as a local write would.
    private func enqueueLocal(_ local: Task, in database: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try database.saveUser(User(
            id: userId, email: "me@example.com", displayName: "Me", photoURL: nil,
            preferences: User.encodePreferences(.defaults), createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1
        ))
        try database.write { db in try local.save(db) }
        try database.saveSyncItem(SyncQueueBuilder.makeItem(
            entityType: "tasks", entityId: taskId, operationType: .update,
            payload: local, now: AppDatabase.currentTimestamp()
        ))
    }

    private func onlyQueueItem(_ database: AppDatabase) throws -> SyncQueueItem {
        let items = try database.read { db in try SyncQueueItem.fetchAll(db) }
        XCTAssertEqual(items.count, 1)
        return try XCTUnwrap(items.first)
    }

    private func makeSut(_ database: AppDatabase, _ store: FakeDocStore) -> SyncService {
        SyncService(database: database, currentAuthUid: { [userId] in userId }, docStore: store)
    }

    // MARK: - LWW outcomes

    func testLocalWins_writesLocalPayloadAndCompletesItem() async throws {
        let database = try AppDatabase.makeTestInstance()
        let store = FakeDocStore()
        store.docs[path] = try remoteDoc(makeTask(version: 2, updatedAt: "2026-09-24T12:00:00.000Z", title: "remote"))
        try enqueueLocal(makeTask(version: 3, updatedAt: "2026-09-24T10:00:00.000Z", title: "local title"), in: database)

        let result = await makeSut(database, store).pushSync(userId: userId)

        XCTAssertEqual([result.pushed, result.conflicts, result.failed], [1, 0, 0])
        XCTAssertEqual(store.writes.count, 1)
        let write = try XCTUnwrap(store.writes.first)
        XCTAssertEqual(write.path, path)
        XCTAssertEqual(write.data["title"] as? String, "local title")
        XCTAssertEqual(write.data["version"] as? Int, 3)
        XCTAssertNotNil(write.data["_syncedAt"], "writeFirestoreDoc's wire shaping must run before the store")
        XCTAssertEqual(try onlyQueueItem(database).status, .completed)
    }

    func testRemoteWins_noRemoteWrite_localOverwritten_itemCompletedNotReenqueued() async throws {
        let database = try AppDatabase.makeTestInstance()
        let store = FakeDocStore()
        store.docs[path] = try remoteDoc(makeTask(version: 5, updatedAt: "2026-09-24T09:00:00.000Z", title: "remote title"))
        try enqueueLocal(makeTask(version: 4, updatedAt: "2026-09-24T11:00:00.000Z", title: "local title"), in: database)

        let result = await makeSut(database, store).pushSync(userId: userId)

        XCTAssertEqual([result.pushed, result.conflicts, result.failed], [0, 1, 0])
        XCTAssertTrue(store.writes.isEmpty)
        let local = try XCTUnwrap(try database.fetchTask(id: taskId))
        XCTAssertEqual(local.version, 5)
        XCTAssertEqual(local.title, "remote title")
        XCTAssertEqual(try onlyQueueItem(database).status, .completed)
    }

    func testEqualVersionOlderLocalTimestamp_remoteWinsTieBreak() async throws {
        let database = try AppDatabase.makeTestInstance()
        let store = FakeDocStore()
        store.docs[path] = try remoteDoc(makeTask(version: 2, updatedAt: "2026-09-24T12:00:00.000Z", title: "remote title"))
        try enqueueLocal(makeTask(version: 2, updatedAt: "2026-09-24T11:59:59.000Z", title: "local title"), in: database)

        let result = await makeSut(database, store).pushSync(userId: userId)

        XCTAssertEqual([result.pushed, result.conflicts, result.failed], [0, 1, 0])
        XCTAssertTrue(store.writes.isEmpty)
        let local = try XCTUnwrap(try database.fetchTask(id: taskId))
        XCTAssertEqual(local.title, "remote title")
        XCTAssertEqual(local.updatedAt, "2026-09-24T12:00:00.000Z")
        XCTAssertEqual(try onlyQueueItem(database).status, .completed)
    }

    func testWriteFailure_itemFailedWithRetryCountPlusOneAndErrorRecorded() async throws {
        let database = try AppDatabase.makeTestInstance()
        let store = FakeDocStore()
        store.docs[path] = try remoteDoc(makeTask(version: 1, updatedAt: "2026-09-24T09:00:00.000Z", title: "r"))
        store.writeError = FakeWriteError()
        try enqueueLocal(makeTask(version: 3, updatedAt: "2026-09-24T10:00:00.000Z", title: "local title"), in: database)
        let sut = makeSut(database, store)

        let result = await sut.pushSync(userId: userId)

        XCTAssertEqual([result.pushed, result.conflicts, result.failed], [0, 0, 1])
        XCTAssertTrue(store.writes.isEmpty)
        let item = try onlyQueueItem(database)
        XCTAssertEqual(item.status, .failed)
        XCTAssertEqual(item.retryCount, 1)
        XCTAssertEqual(item.lastError, "unavailable: offline")
        XCTAssertEqual(sut.lastError?.message, "unavailable: offline")
        XCTAssertEqual(try database.fetchTask(id: taskId)?.title, "local title")
    }
}
