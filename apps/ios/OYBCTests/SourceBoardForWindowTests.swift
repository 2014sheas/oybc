import GRDB
import XCTest
@testable import OYBC

/// Owner ruling 2026-09-24 — ENDED BOARDS ARE NEVER SOURCES. A stored board
/// source resolves, for the window starting at `reference`, to:
///   - `.live`     — an open board supplies it;
///   - `.noWindow` — the source exists but has no open board for the window
///                   (ended/sealed one-off; a series with no instance
///                   containing the reference) → no supply, "No board for
///                   this window yet";
///   - `.dead`     — the stored row is gone / deleted / archived, or the
///                   series has no existing instance → the spawn's ask.
///
/// Also pins the Sources sheet fetcher, the ask's removal action, the spawn
/// (nothing dealt + the provenance note), and capacity == Preview == deal.
/// Web twins: `db/operations/__tests__/sourceBoardForWindow.test.ts`,
/// `sourceSheetBoardEntries.test.ts`, `recurringBoardSpawnMix.test.ts`, and
/// the parity block in `pages/createHub/__tests__/resolveDraftCapacity.test.ts`.
final class SourceBoardForWindowTests: XCTestCase {

    private let userId = "u1"
    private let stamp = "2026-09-01T00:00:00.000Z"
    // Local-ISO board dates (the board-date convention). "Now" = Wed 2026-09-16 noon.
    private let now = parseISO8601Date("2026-09-16T12:00:00.000")!
    private let refThisWeek = "2026-09-14T00:00:00.000"
    private let thisWeek = (start: "2026-09-14T00:00:00.000", end: "2026-09-20T23:59:59.999")
    private let lastWeek = (start: "2026-09-07T00:00:00.000", end: "2026-09-13T23:59:59.999")
    private let nextWeek = (start: "2026-09-21T00:00:00.000", end: "2026-09-27T23:59:59.999")

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try db.write { grdb in
            try User(
                id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: stamp, updatedAt: stamp, lastSyncedAt: nil, version: 1
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
            createdAt: stamp, updatedAt: stamp,
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

    /// A weekly board with `taskIds` placed row-major.
    private func seedBoard(
        _ db: AppDatabase,
        id: String,
        name: String? = nil,
        window: (start: String, end: String),
        taskIds: [String] = [],
        status: String = "active",
        isDeleted: Bool = false,
        sealedAt: String? = nil,
        series: String? = nil
    ) throws {
        try insertTasks(db, taskIds)
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": name ?? "Board \(id)",
            "status": status, "boardSize": 3, "timeframe": "weekly",
            "startDate": window.start, "endDate": window.end,
            "centerSquareType": "none", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": stamp, "updatedAt": stamp, "version": 1, "isDeleted": isDeleted,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        if let series { dict["spawnedFromTemplateId"] = series }
        let board = try decodeBoard(dict)
        try db.write { grdb in
            try board.insert(grdb)
            for (i, taskId) in taskIds.enumerated() {
                try BoardTask(
                    id: "bt-\(id)-\(taskId)", boardId: id, taskId: taskId,
                    row: i / 3, col: i % 3, isCenter: false,
                    createdAt: stamp, updatedAt: stamp,
                    lastSyncedAt: nil, version: 1, isDeleted: false
                ).insert(grdb)
            }
        }
    }

    private func resolve(_ db: AppDatabase, _ id: String) throws -> AppDatabase.SourceBoardResolution {
        try db.read { grdb in
            try AppDatabase.resolveSourceBoardForWindow(
                db: grdb, storedBoardId: id, reference: refThisWeek, now: now
            )
        }
    }

    private func isLive(_ r: AppDatabase.SourceBoardResolution, id: String) -> Bool {
        if case .live(let b) = r { return b.id == id }
        return false
    }

    private func isNoWindow(_ r: AppDatabase.SourceBoardResolution) -> Bool {
        if case .noWindow = r { return true }
        return false
    }

    private func isDead(_ r: AppDatabase.SourceBoardResolution) -> Bool {
        if case .dead = r { return true }
        return false
    }

    // MARK: - One-off boards

    func test_openOneOff_resolvesLive() throws {
        let db = try makeDb()
        try seedBoard(db, id: "open", window: thisWeek, taskIds: ["t1"])
        XCTAssertTrue(isLive(try resolve(db, "open"), id: "open"))
    }

    func test_endedOneOff_resolvesNoWindow_nullSupply() throws {
        let db = try makeDb()
        try seedBoard(db, id: "ended", name: "Last week", window: lastWeek, taskIds: ["t1"])
        guard case .noWindow(let name) = try resolve(db, "ended") else {
            return XCTFail("expected .noWindow")
        }
        XCTAssertEqual(name, "Last week")
        XCTAssertNil(try db.fetchBoardSourceSupply(boardId: "ended", reference: refThisWeek, now: now))
    }

    func test_sealedOneOff_resolvesNoWindow() throws {
        let db = try makeDb()
        try seedBoard(db, id: "sealed", window: thisWeek, sealedAt: "2026-09-15T00:00:00.000Z")
        XCTAssertTrue(isNoWindow(try resolve(db, "sealed")))
    }

    func test_deletedArchivedOrMissingOneOff_isDead() throws {
        let db = try makeDb()
        try seedBoard(db, id: "deleted", window: thisWeek, isDeleted: true)
        try seedBoard(db, id: "archived", window: thisWeek, status: "archived")
        XCTAssertTrue(isDead(try resolve(db, "deleted")))
        XCTAssertTrue(isDead(try resolve(db, "archived")))
        XCTAssertTrue(isDead(try resolve(db, "nope")))
    }

    // MARK: - Series binding

    func test_series_bindsToTheInstanceContainingTheReference() throws {
        let db = try makeDb()
        try seedBoard(db, id: "wk-last", window: lastWeek, series: "series-1")
        try seedBoard(db, id: "wk-this", window: thisWeek, series: "series-1")
        XCTAssertTrue(isLive(try resolve(db, "wk-last"), id: "wk-this"))
    }

    func test_series_noContainingInstance_isNoWindow_notTheEndedOne() throws {
        // Only last week exists — the old fallback returned it ("newest started").
        let db = try makeDb()
        try seedBoard(db, id: "wk-last", window: lastWeek, series: "series-1")
        XCTAssertTrue(isNoWindow(try resolve(db, "wk-last")))
    }

    func test_series_neverBindsToAFutureInstance() throws {
        let db = try makeDb()
        try seedBoard(db, id: "wk-next", window: nextWeek, series: "series-1")
        XCTAssertTrue(isNoWindow(try resolve(db, "wk-next")))
    }

    func test_series_everyInstanceArchived_isDead() throws {
        let db = try makeDb()
        try seedBoard(db, id: "a1", window: thisWeek, status: "archived", series: "series-x")
        XCTAssertTrue(isDead(try resolve(db, "a1")))
    }

    // MARK: - The Sources sheet ("Add from a pool or board")

    func test_sheetEntries_excludeAnEndedAndASealedBoard() throws {
        let db = try makeDb()
        try seedBoard(db, id: "open", window: thisWeek)
        try seedBoard(db, id: "ended", window: lastWeek)
        try seedBoard(db, id: "sealed", window: thisWeek, sealedAt: "2026-09-15T00:00:00.000Z")
        let ids = try db.fetchSourceSheetBoardEntries(userId: userId, now: now).map { $0.board.id }
        XCTAssertEqual(ids, ["open"])
    }

    // MARK: - The ask: no board for this window is NOT a missing source

    private func template(sources: [BoardSource], manual: [String] = []) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: "tpl-1", userId: userId, name: "Daily",
            timeframe: .daily, boardSize: 3, centerSquareType: .free,
            isRandomized: true, seedTaskIds: [],
            manualTaskIds: manual, sources: sources,
            lastSpawnedWindowKey: nil, isActive: true,
            createdAt: stamp, updatedAt: stamp,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    func test_removeMissingBoardSources_keepsASeriesSourceWithNoCurrentInstance() throws {
        // Last week relative to the wall clock too → `.noWindow`, never `.dead`.
        let db = try makeDb()
        try seedBoard(db, id: "wk-last", window: lastWeek, series: "series-1")
        let t = template(sources: [BoardSource(sourceId: "wk-last", kind: .board)])
        try db.write { grdb in try t.insert(grdb) }
        XCTAssertFalse(try db.removeMissingBoardSources(templateId: "tpl-1", now: stamp))
        let stored = try db.read { grdb in try RecurringBoardTemplate.fetchOne(grdb, key: "tpl-1") }
        XCTAssertEqual(stored?.sources?.map { $0.sourceId }, ["wk-last"])
    }

    // MARK: - Spawn + capacity == Preview == deal

    /// A pool of 8 (fills a 3×3 FREE board exactly) + a weekly series whose
    /// only instance ENDED yesterday, both relative to the WALL CLOCK — the
    /// wizard VM resolves with `Date()`, so this parity fixture must too.
    private func seedParityFixture(_ db: AppDatabase) throws -> (pool: [String], series: [String], windowStart: String, windowEnd: String) {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let lastWeekStart = cal.date(byAdding: .day, value: -8, to: todayStart)!
        let lastWeekEnd = cal.date(byAdding: .day, value: -1, to: todayStart)!.addingTimeInterval(-0.001)
        let poolIds = (0..<8).map { "p\($0)" }
        let seriesIds = ["s1", "s2", "s3"]
        try insertTasks(db, poolIds)
        let pool = Pool(
            id: "pool-1", userId: userId, name: "Pool", taskIds: poolIds,
            createdAt: stamp, updatedAt: stamp, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
        try db.write { grdb in try pool.insert(grdb) }
        try seedBoard(
            db, id: "wk-last",
            window: (wizardLocalISOString(lastWeekStart), wizardLocalISOString(lastWeekEnd)),
            taskIds: seriesIds, series: "series-weekly"
        )
        let windowEnd = cal.date(byAdding: .day, value: 1, to: todayStart)!.addingTimeInterval(-0.001)
        return (poolIds, seriesIds, wizardLocalISOString(todayStart), wizardLocalISOString(windowEnd))
    }

    func test_capacity_equals_preview_equals_deal_forASeriesWithNoCurrentInstance() throws {
        let db = try makeDb()
        let f = try seedParityFixture(db)
        let sources = [
            BoardSource(sourceId: "pool-1", kind: .pool),
            BoardSource(sourceId: "wk-last", kind: .board),
        ]
        let mix = RecurringDraftMixPayload(
            poolIds: ["pool-1"], manualTaskIds: [], removedTaskIds: [], sources: sources
        )
        let draft = try decodeBoard([
            "id": "draft-1", "userId": userId, "name": "Daily",
            "status": "draft", "boardSize": 3, "timeframe": "daily",
            "startDate": f.windowStart, "endDate": f.windowEnd,
            "centerSquareType": "free", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": stamp, "updatedAt": stamp, "version": 1, "isDeleted": false,
            "isRecurringDraft": true,
            "recurringDraftMix": try XCTUnwrap(mix.encoded()),
        ])

        // 1. Drafts-list capacity.
        let capacity = BoardWizardViewModel.resolveDraftCapacity(board: draft, database: db)

        // 2. The reopened wizard's live supply (Preview plans from it).
        let vm = BoardWizardViewModel(preferences: .defaults, draft: (draft, []), database: db)
        XCTAssertTrue(vm.supplyInfoBySourceId["wk-last"]?.noBoardForWindow == true)
        let preview = vm.sourceCapacity

        // 3. The spawned deal for the same window.
        let t = template(sources: sources)
        try db.write { grdb in try t.insert(grdb) }
        let outcome = try db.spawnRecurringBoard(
            PendingTemplateSpawn(
                template: t, windowStart: f.windowStart, windowEnd: f.windowEnd,
                suggestedName: "Daily"
            ),
            boardId: "spawned-1",
            now: stamp
        )
        guard case .spawned(let boardId, _, _, let windowless) = outcome else {
            return XCTFail("expected a spawn, got \(outcome)")
        }
        let dealt = try db.read { grdb in
            try BoardTask.filter(Column("boardId") == boardId).fetchAll(grdb).map { $0.taskId }
        }

        XCTAssertEqual(capacity, 8)
        XCTAssertEqual(preview, capacity)
        XCTAssertEqual(dealt.count, capacity)
        for id in f.series { XCTAssertFalse(dealt.contains(id), id) }
        XCTAssertEqual(windowless, ["wk-last"])

        // The spawn note records the windowless source.
        let note = db.spawnProvenanceNote(
            template: t,
            poolsById: ["pool-1": try XCTUnwrap(db.fetchPools(ids: ["pool-1"]).first)],
            tasksById: Dictionary(uniqueKeysWithValues: try db.fetchTasks(ids: f.pool).map { ($0.id, $0) }),
            dealtTaskIds: dealt,
            windowStart: f.windowStart
        )
        XCTAssertTrue(note.hasSuffix(" · No board for this window yet"), note)
    }
}
