import GRDB
import XCTest
@testable import OYBC

/// The loaders that used to live inline in views (or reached for
/// `AppDatabase.shared` past an injected database) now read through the
/// injected instance: the board wizard's Sources-sheet catalog, the Create
/// hub's drafts list (`AppDatabase.fetchDraftBoards`), and the linked-counter
/// caption's source title.
///
/// Every test seeds an isolated `makeTestInstance()` under a user id that the
/// production database never holds, so a loader that still read `.shared`
/// would come back empty and fail the assertions.
final class ViewDbSeamLoaderTests: XCTestCase {

    private let userId = "u-view-seam"
    private static let ts = "2026-09-01T12:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db, id: userId)
        return db
    }

    private func seedUser(_ db: AppDatabase, id: String) throws {
        try db.saveUser(User(
            id: id, email: "\(id)@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: Self.ts, updatedAt: Self.ts, lastSyncedAt: nil, version: 1
        ))
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    @discardableResult
    private func seedBoard(
        _ db: AppDatabase,
        id: String,
        name: String = "Board",
        status: String = "active",
        updatedAt: String = "2026-09-01T12:00:00.000Z",
        startDate: String? = nil,
        isCore: Bool = false,
        isDeleted: Bool = false,
        userId: String? = nil
    ) throws -> Board {
        let day: TimeInterval = 24 * 60 * 60
        let dict: [String: Any] = [
            "id": id, "userId": userId ?? self.userId, "name": name,
            "status": status, "boardSize": 3, "timeframe": "daily",
            "startDate": startDate ?? iso(Date().addingTimeInterval(-day)),
            "endDate": iso(Date().addingTimeInterval(5 * day)),
            "centerSquareType": "none", "isRandomized": true, "isCore": isCore,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": Self.ts, "updatedAt": updatedAt,
            "version": 1, "isDeleted": isDeleted,
        ]
        let board = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
        try db.write { grdb in try board.insert(grdb) }
        return board
    }

    private func seedTask(_ db: AppDatabase, id: String, title: String, isDeleted: Bool = false) throws {
        let task = OYBC.Task(
            id: id, userId: userId, title: title, description: nil, type: .counting,
            action: "Read", unit: "pages", maxCount: 35,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: 0,
            createdAt: Self.ts, updatedAt: Self.ts,
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
        try db.write { grdb in try task.insert(grdb) }
    }

    // MARK: - Board wizard: Sources-sheet catalog

    func test_loadSourceCatalog_readsTheInjectedDatabase() async throws {
        let db = try makeDb()
        let pool = try db.createPoolAndEnqueue(
            userId: userId, name: "Morning", taskIds: [], now: AppDatabase.currentTimestamp()
        )
        try seedBoard(db, id: "b-src", name: "This week")
        let vm = BoardWizardViewModel(preferences: .defaults, database: db)

        let catalog = try await vm.loadSourceCatalog(userId: userId)

        XCTAssertEqual(catalog.pools.map(\.id), [pool.id])
        XCTAssertEqual(catalog.boardEntries.map(\.board.id), ["b-src"])
        XCTAssertEqual(catalog.boardEntries.first?.board.name, "This week")
        XCTAssertEqual(catalog.boardEntries.first?.squares, 0)
        XCTAssertTrue(catalog.templates.isEmpty)
    }

    func test_loadSourceCatalog_cancelled_throwsInsteadOfReturning() async throws {
        let db = try makeDb()
        try seedBoard(db, id: "b-src")
        let vm = BoardWizardViewModel(preferences: .defaults, database: db)
        let uid = userId

        // Cancel from inside the task before the load starts, so the outcome
        // does not depend on scheduling.
        let load = _Concurrency.Task { () async throws -> WizardSourceCatalog in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await vm.loadSourceCatalog(userId: uid)
        }

        do {
            let catalog = try await load.value
            XCTFail("a cancelled load must not return a catalog, got \(catalog.boardEntries.count) boards")
        } catch is CancellationError {
            // expected
        }
    }

    // MARK: - Create hub: drafts

    func test_fetchDraftBoards_liveDraftsOfThisUserOnly_newestFirst_healed() throws {
        let db = try makeDb()
        try seedUser(db, id: "someone-else")
        try seedBoard(db, id: "d-old", name: "Old draft", status: "draft", updatedAt: "2026-09-01T08:00:00.000Z")
        try seedBoard(db, id: "d-new", name: "Today", status: "draft", updatedAt: "2026-09-02T08:00:00.000Z",
                      startDate: "2026-03-15T00:00:00.000", isCore: true)
        try seedBoard(db, id: "active", status: "active")
        try seedBoard(db, id: "d-deleted", status: "draft", isDeleted: true)
        try seedBoard(db, id: "d-other-user", status: "draft", userId: "someone-else")

        let drafts = try db.fetchDraftBoards(userId: userId)

        XCTAssertEqual(drafts.map(\.id), ["d-new", "d-old"])
        XCTAssertEqual(drafts.first?.name, "Mar 15, 2026", "display names are healed like every other board read")
    }

    func test_createHubReloadDrafts_readsTheInjectedDatabase() throws {
        let db = try makeDb()
        try seedBoard(db, id: "d-1", name: "My draft", status: "draft")
        let vm = CreateHubViewModel(database: db)

        vm.reloadDrafts(userId: userId)

        let loaded = expectation(for: NSPredicate { _, _ in !vm.drafts.isEmpty }, evaluatedWith: nil)
        wait(for: [loaded], timeout: 5)
        XCTAssertEqual(vm.drafts.map(\.board.id), ["d-1"])
        XCTAssertEqual(vm.drafts.first?.taskCount, 0)
    }

    // MARK: - Linked-counter caption

    func test_captionSourceTitle_liveSource_isItsTitle() throws {
        let db = try makeDb()
        try seedTask(db, id: "root", title: "Read 35 pages")

        XCTAssertEqual(
            try LinkedCounterCaptionView.resolveSourceTitle(database: db, sharedCounterId: "root"),
            "Read 35 pages"
        )
    }

    func test_captionSourceTitle_deletedOrMissingSource_isNil() throws {
        let db = try makeDb()
        try seedTask(db, id: "gone", title: "Deleted root", isDeleted: true)

        XCTAssertNil(try LinkedCounterCaptionView.resolveSourceTitle(database: db, sharedCounterId: "gone"))
        XCTAssertNil(try LinkedCounterCaptionView.resolveSourceTitle(database: db, sharedCounterId: "never-existed"))
    }
}
