import GRDB
import XCTest
@testable import OYBC

/// 2026-09 audit T2 — the Create hub's drafts-list count and resume step
/// used to resolve a draft through the retired pool-mix mirror
/// (`poolIds` / `removedTaskIds`). That mirror carries no board-kind
/// sources and no ranges, so:
///   - a draft pulling ONLY a board counted 0 and reopened on Setup;
///   - a pool source capped by `max` counted the whole pool.
/// These fixtures are exactly those shapes; each literal is the number the
/// reopened wizard's capacity shows, not the old read's. Web mirror:
/// `apps/web/src/pages/createHub/__tests__/resolveDraftCapacity.test.ts`.
final class DraftSourcesCapacityTests: XCTestCase {

    private let userId = "u1"
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

    private func makeTask(_ id: String) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: userId, title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func insertTasks(_ db: AppDatabase, _ ids: [String]) throws {
        try db.write { grdb in
            for id in ids where try OYBC.Task.fetchOne(grdb, key: id) == nil {
                try makeTask(id).insert(grdb)
            }
        }
    }

    private func decodeBoard(_ dict: [String: Any]) throws -> Board {
        try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    /// An ACTIVE one-off 3×3 source board with `taskIds` placed row-major.
    private func seedSourceBoard(_ db: AppDatabase, id: String, taskIds: [String]) throws {
        try insertTasks(db, taskIds)
        let board = try decodeBoard([
            "id": id, "userId": userId, "name": "Source \(id)",
            "status": "active", "boardSize": 3, "timeframe": "custom",
            "startDate": now, "endDate": "2099-12-31T23:59:59.999",
            "centerSquareType": "none", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ])
        try db.write { grdb in
            try board.insert(grdb)
            for (i, taskId) in taskIds.enumerated() {
                try BoardTask(
                    id: "bt-\(id)-\(taskId)", boardId: id, taskId: taskId,
                    row: i / 3, col: i % 3, isCenter: false,
                    createdAt: now, updatedAt: now,
                    lastSyncedAt: nil, version: 1, isDeleted: false
                ).insert(grdb)
            }
        }
    }

    private func seedPool(_ db: AppDatabase, id: String, taskIds: [String]) throws {
        try insertTasks(db, taskIds)
        let pool = Pool(
            id: id, userId: userId, name: "Pool \(id)", taskIds: taskIds,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
        try db.write { grdb in try pool.insert(grdb) }
    }

    /// A 3×3 FREE-center draft (8 fillable cells) whose blob carries
    /// `sources`, with the legacy mirror the wizard's dual-write produces:
    /// `poolIds` lists pool-kind sources only — so a board-only draft's
    /// mirror is EMPTY.
    private func draftBoard(sources: [BoardSource], manualTaskIds: [String] = []) throws -> Board {
        let mix = RecurringDraftMixPayload(
            poolIds: sources.filter { $0.kind == .pool }.map { $0.sourceId },
            manualTaskIds: manualTaskIds,
            removedTaskIds: [],
            sources: sources
        )
        return try decodeBoard([
            "id": "draft-1", "userId": userId, "name": "Draft",
            "status": "draft", "boardSize": 3, "timeframe": "custom",
            "startDate": now, "endDate": "2099-12-31T23:59:59.999",
            "centerSquareType": "free", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
            "recurringDraftMix": try XCTUnwrap(mix.encoded()),
        ])
    }

    // MARK: - Drafts-list count

    func test_boardOnlyDraft_countsTheBoardSupply_notZero() throws {
        let db = try makeDb()
        try seedSourceBoard(db, id: "src-board", taskIds: ["b1", "b2", "b3", "b4"])
        let draft = try draftBoard(sources: [BoardSource(sourceId: "src-board", kind: .board)])

        XCTAssertEqual(BoardWizardViewModel.resolveDraftCapacity(board: draft, database: db), 4)
    }

    func test_poolSourceCappedByMax_countsTheCap_notTheWholePool() throws {
        let db = try makeDb()
        let ids = (0..<10).map { "p\($0)" }
        try seedPool(db, id: "pool-1", taskIds: ids)
        let draft = try draftBoard(sources: [BoardSource(sourceId: "pool-1", kind: .pool, max: 3)])

        XCTAssertEqual(BoardWizardViewModel.resolveDraftCapacity(board: draft, database: db), 3)
    }

    func test_manualTaskOutsideEverySource_addsToABoardSource() throws {
        let db = try makeDb()
        try seedSourceBoard(db, id: "src-board", taskIds: ["b1", "b2"])
        try insertTasks(db, ["m1"])
        let draft = try draftBoard(
            sources: [BoardSource(sourceId: "src-board", kind: .board)],
            manualTaskIds: ["m1"]
        )

        XCTAssertEqual(BoardWizardViewModel.resolveDraftCapacity(board: draft, database: db), 3)
    }

    func test_v1BlobWithoutSources_mapsForwardThroughTheDecoder() throws {
        let db = try makeDb()
        try seedPool(db, id: "pool-v1", taskIds: ["a", "b", "c"])
        let v1 = #"{"poolIds":["pool-v1"],"manualTaskIds":[],"removedTaskIds":["b"]}"#
        let draft = try decodeBoard([
            "id": "draft-v1", "userId": userId, "name": "Draft",
            "status": "draft", "boardSize": 3, "timeframe": "custom",
            "startDate": now, "centerSquareType": "free", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
            "recurringDraftMix": v1,
        ])

        XCTAssertEqual(BoardWizardViewModel.resolveDraftCapacity(board: draft, database: db), 2)
    }

    // MARK: - Resume step

    func test_boardOnlyDraft_resumesOnTasksStep_notSetup() throws {
        let db = try makeDb()
        try seedSourceBoard(db, id: "src-board", taskIds: ["b1", "b2", "b3", "b4"])
        let draft = try draftBoard(sources: [BoardSource(sourceId: "src-board", kind: .board)])

        XCTAssertEqual(
            BoardWizardViewModel.resolveDraftInitialStep(board: draft, boardTasks: [], database: db), 2
        )
    }

    func test_cappedPoolDraft_resumesOnTasksStep_notPreview() throws {
        let db = try makeDb()
        try seedPool(db, id: "pool-1", taskIds: (0..<10).map { "p\($0)" })
        let draft = try draftBoard(sources: [BoardSource(sourceId: "pool-1", kind: .pool, max: 3)])

        XCTAssertEqual(
            BoardWizardViewModel.resolveDraftInitialStep(board: draft, boardTasks: [], database: db), 2
        )
    }

    func test_boardSourceThatFillsTheGrid_resumesOnPreview() throws {
        let db = try makeDb()
        try seedSourceBoard(db, id: "src-board", taskIds: (1...8).map { "b\($0)" })
        let draft = try draftBoard(sources: [BoardSource(sourceId: "src-board", kind: .board)])

        XCTAssertEqual(
            BoardWizardViewModel.resolveDraftInitialStep(board: draft, boardTasks: [], database: db), 3
        )
    }
}
