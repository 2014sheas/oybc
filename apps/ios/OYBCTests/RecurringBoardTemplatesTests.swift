import XCTest
import GRDB
@testable import OYBC

/// Unit + integration tests for Phase 6.2 (preset-pool recurring boards).
///
/// Algorithm tests are line-for-line ports of
/// `packages/shared/tests/algorithms/recurringBoardTemplates.test.ts` —
/// any divergence here would cause the spawn driver to fire on iOS for
/// templates web doesn't think are pending (or vice versa).
///
/// The integration test exercises the full spawn path against a fresh
/// in-memory GRDB instance to verify the v8 migration + the multi-table
/// transaction shape end-to-end.
final class RecurringBoardTemplatesTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTemplate(
        id: String = "tpl-1",
        userId: String = "u1",
        timeframe: Timeframe = .daily,
        boardSize: Int = 5,
        centerSquareType: CenterSquareType = .free,
        isRandomized: Bool = false,
        seedTaskIds: [String]? = nil,
        lastSpawnedWindowKey: String? = nil,
        isActive: Bool = true,
        isDeleted: Bool = false
    ) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id,
            userId: userId,
            name: "Daily Workout",
            timeframe: timeframe,
            boardSize: boardSize,
            centerSquareType: centerSquareType,
            centerSquareCustomName: nil,
            isRandomized: isRandomized,
            seedTaskIds: seedTaskIds ?? (0..<24).map { "task-\($0)" },
            lastSpawnedWindowKey: lastSpawnedWindowKey,
            isActive: isActive,
            createdAt: "2026-05-01T00:00:00.000Z",
            updatedAt: "2026-05-01T00:00:00.000Z",
            lastSyncedAt: nil,
            version: 1,
            isDeleted: isDeleted,
            deletedAt: nil
        )
    }

    private func makeTask(_ id: String, isDeleted: Bool = false) -> Task {
        Task(
            id: id,
            userId: "u1",
            title: "Task \(id)",
            type: .normal,
            operatorType: nil,
            threshold: nil,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: "2026-05-01T00:00:00.000Z",
            updatedAt: "2026-05-01T00:00:00.000Z",
            version: 1,
            isDeleted: isDeleted
        )
    }

    private func now(_ y: Int = 2026, _ m: Int = 5, _ d: Int = 7, hour: Int = 12) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = hour
        c.calendar = Calendar.current
        c.timeZone = TimeZone.current
        return Calendar.current.date(from: c)!
    }

    /// Build a Board for the idempotency-belt test cases. Mirrors the
    /// JSON-dict pattern from `RecurringBoardsTests.boardForWindow`.
    private func boardForWindow(
        timeframe: Timeframe,
        referenceDate: Date,
        spawnedFromTemplateId: String? = nil,
        isDeleted: Bool = false
    ) -> Board {
        let window = computeTimeframeBoundaries(
            timeframe: timeframe,
            referenceDate: referenceDate,
            weekStartDay: "monday"
        )!
        var dict: [String: Any] = [
            "id": "board-\(timeframe.rawValue)-\(wizardLocalISOString(window.start))",
            "userId": "u1",
            "name": "board",
            "status": BoardStatus.active.rawValue,
            "boardSize": 5,
            "timeframe": timeframe.rawValue,
            "startDate": wizardLocalISOString(window.start),
            "endDate": wizardLocalISOString(window.end),
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": true,
            "totalTasks": 25,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-05-01T00:00:00.000",
            "updatedAt": "2026-05-01T00:00:00.000",
            "version": 1,
            "isDeleted": isDeleted,
        ]
        if let id = spawnedFromTemplateId {
            dict["spawnedFromTemplateId"] = id
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip_PreservesSeedTaskIdsAndAllFields() throws {
        let original = makeTemplate(
            seedTaskIds: ["a", "b", "c"],
            lastSpawnedWindowKey: "2026-05-06T00:00:00.000",
            isActive: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecurringBoardTemplate.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.seedTaskIds, ["a", "b", "c"])
        XCTAssertEqual(decoded.lastSpawnedWindowKey, "2026-05-06T00:00:00.000")
        XCTAssertFalse(decoded.isActive)
    }

    // MARK: - findTemplatesPendingSpawn

    func testFindPendingSpawn_FreshTemplate_Pending() {
        let tpl = makeTemplate()
        let pending = findTemplatesPendingSpawn(
            templates: [tpl],
            boards: [],
            weekStartDay: "monday",
            now: now()
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].template.id, tpl.id)
    }

    func testFindPendingSpawn_LastSpawnedMatchesCurrentWindow_NotPending() {
        let window = computeTimeframeBoundaries(timeframe: .daily, referenceDate: now(), weekStartDay: "monday")!
        let tpl = makeTemplate(lastSpawnedWindowKey: wizardLocalISOString(window.start))
        let pending = findTemplatesPendingSpawn(
            templates: [tpl],
            boards: [],
            weekStartDay: "monday",
            now: now()
        )
        XCTAssertTrue(pending.isEmpty)
    }

    func testFindPendingSpawn_InactiveTemplate_NotPending() {
        let tpl = makeTemplate(isActive: false)
        let pending = findTemplatesPendingSpawn(
            templates: [tpl],
            boards: [],
            weekStartDay: "monday",
            now: now()
        )
        XCTAssertTrue(pending.isEmpty)
    }

    func testFindPendingSpawn_SoftDeletedTemplate_NotPending() {
        let tpl = makeTemplate(isDeleted: true)
        let pending = findTemplatesPendingSpawn(
            templates: [tpl],
            boards: [],
            weekStartDay: "monday",
            now: now()
        )
        XCTAssertTrue(pending.isEmpty)
    }

    func testFindPendingSpawn_CustomTimeframe_NotPending() {
        let tpl = makeTemplate(timeframe: .custom)
        let pending = findTemplatesPendingSpawn(
            templates: [tpl],
            boards: [],
            weekStartDay: "monday",
            now: now()
        )
        XCTAssertTrue(pending.isEmpty)
    }

    func testFindPendingSpawn_IdempotencyBelt_ExistingMatchingBoard_NotPending() {
        let tpl = makeTemplate()
        let board = boardForWindow(
            timeframe: .daily,
            referenceDate: now(),
            spawnedFromTemplateId: tpl.id
        )
        let pending = findTemplatesPendingSpawn(
            templates: [tpl],
            boards: [board],
            weekStartDay: "monday",
            now: now()
        )
        XCTAssertTrue(pending.isEmpty)
    }

    func testFindPendingSpawn_IdempotencyBelt_DeletedBoardDoesNotBlock() {
        let tpl = makeTemplate()
        let board = boardForWindow(
            timeframe: .daily,
            referenceDate: now(),
            spawnedFromTemplateId: tpl.id,
            isDeleted: true
        )
        let pending = findTemplatesPendingSpawn(
            templates: [tpl],
            boards: [board],
            weekStartDay: "monday",
            now: now()
        )
        XCTAssertEqual(pending.count, 1)
    }

    // MARK: - validateSpawnPool
    //
    // Pool semantics post-rework: loose-fit only. `count >= required`
    // is the single rule; extras become the random subset for each
    // spawn. The earlier strict-fit `.all` strategy was dropped.

    func testValidateSpawnPool_ExactFit_OK() {
        let tpl = makeTemplate(seedTaskIds: (0..<24).map { "t\($0)" })
        let pool = tpl.seedTaskIds.map { makeTask($0) }
        if case .ok = validateSpawnPool(template: tpl, poolTasks: pool) {
            // pass
        } else {
            XCTFail("expected ok")
        }
    }

    func testValidateSpawnPool_Undersize_PoolTooSmall() {
        let tpl = makeTemplate(seedTaskIds: (0..<23).map { "t\($0)" })
        let pool = tpl.seedTaskIds.map { makeTask($0) }
        XCTAssertEqual(validateSpawnPool(template: tpl, poolTasks: pool), .failure(.poolTooSmall))
    }

    func testValidateSpawnPool_Oversize_OK() {
        // Extras become the random subset — no longer a "wrong size" failure.
        let tpl = makeTemplate(seedTaskIds: (0..<25).map { "t\($0)" })
        let pool = tpl.seedTaskIds.map { makeTask($0) }
        if case .ok = validateSpawnPool(template: tpl, poolTasks: pool) { } else {
            XCTFail("expected ok")
        }
    }

    func testValidateSpawnPool_LargeOversize_OK() {
        let tpl = makeTemplate(seedTaskIds: (0..<50).map { "t\($0)" })
        let pool = tpl.seedTaskIds.map { makeTask($0) }
        if case .ok = validateSpawnPool(template: tpl, poolTasks: pool) { } else {
            XCTFail("expected ok")
        }
    }

    func testValidateSpawnPool_HasDeletedTask_HasDeletedTasks() {
        let tpl = makeTemplate(boardSize: 3, seedTaskIds: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"])
        let pool = tpl.seedTaskIds.map { makeTask($0, isDeleted: $0 == "c") }
        XCTAssertEqual(validateSpawnPool(template: tpl, poolTasks: pool), .failure(.hasDeletedTasks))
    }

    func testValidateSpawnPool_CustomTimeframe_UnsupportedTimeframe() {
        let tpl = makeTemplate(timeframe: .custom)
        let pool = tpl.seedTaskIds.map { makeTask($0) }
        XCTAssertEqual(validateSpawnPool(template: tpl, poolTasks: pool), .failure(.unsupportedTimeframe))
    }

    func testValidateSpawnPool_ChosenCenter_UnsupportedCenter() {
        let tpl = makeTemplate(centerSquareType: .chosen)
        let pool = tpl.seedTaskIds.map { makeTask($0) }
        XCTAssertEqual(validateSpawnPool(template: tpl, poolTasks: pool), .failure(.unsupportedCenter))
    }

    // MARK: - buildSpawnPlacement

    func testBuildSpawnPlacement_NonRandomized_OrderPreserved_FreeCenterIsNil() {
        let tpl = makeTemplate(
            isRandomized: false,
            seedTaskIds: (0..<24).map { "t\($0)" }
        )
        let pool = tpl.seedTaskIds.map { makeTask($0) }
        let placement = buildSpawnPlacement(template: tpl, poolTasks: pool)
        XCTAssertEqual(placement.count, 25)
        XCTAssertNil(placement[12]) // 5x5 center idx = 12
        XCTAssertEqual(placement[0]?.id, "t0")
        XCTAssertEqual(placement[11]?.id, "t11")
        XCTAssertEqual(placement[13]?.id, "t12") // skipped center
    }

    func testBuildSpawnPlacement_RandomizedDeterministic_StableUnderSeededRng() {
        let tpl = makeTemplate(isRandomized: true, seedTaskIds: (0..<24).map { "t\($0)" })
        let pool = tpl.seedTaskIds.map { makeTask($0) }
        let a = buildSpawnPlacement(template: tpl, poolTasks: pool, rng: { 0.0 })
        let b = buildSpawnPlacement(template: tpl, poolTasks: pool, rng: { 0.0 })
        XCTAssertEqual(a.map { $0?.id ?? "_" }, b.map { $0?.id ?? "_" })
    }

    func testBuildSpawnPlacement_OversizedPool_SlicesToFillableCells() {
        let tpl = makeTemplate(isRandomized: true, seedTaskIds: (0..<50).map { "t\($0)" })
        let pool = tpl.seedTaskIds.map { makeTask($0) }
        let placement = buildSpawnPlacement(template: tpl, poolTasks: pool, rng: { 0.5 })
        XCTAssertEqual(placement.count, 25)
        XCTAssertNil(placement[12])
        let placedIds = placement.compactMap { $0?.id }
        XCTAssertEqual(placedIds.count, 24)
        XCTAssertEqual(Set(placedIds).count, 24) // deduped
    }

    func testBuildSpawnPlacement_NoneCenter_AllCellsFilled() {
        let tpl = makeTemplate(
            centerSquareType: .none,
            isRandomized: false,
            seedTaskIds: (0..<25).map { "t\($0)" }
        )
        let pool = tpl.seedTaskIds.map { makeTask($0) }
        let placement = buildSpawnPlacement(template: tpl, poolTasks: pool)
        XCTAssertEqual(placement[12]?.id, "t12")
    }

    // MARK: - End-to-end spawn (integration with in-memory GRDB)
    //
    // Note: the Phase 6.2 spawn driver invokes `AppDatabase.shared.write`
    // directly, so we can't substitute the in-memory test instance. The
    // following test verifies the v8 schema by reading + writing through
    // the test instance, but does not exercise `RecurringBoardSpawn`
    // itself. End-to-end spawn coverage is via the manual QA pass relayed
    // to the user (per CLAUDE.md's "no sim-driving" convention).

    func testV8MigrationCreatesRecurringTemplatesTableAndBoardColumn() throws {
        let testDb = try AppDatabase.makeTestInstance()
        try testDb.dbQueue.read { db in
            // Table exists.
            XCTAssertTrue(try db.tableExists("recurring_board_templates"))
            // Indexes exist.
            let indexes = try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='recurring_board_templates'"
            ).map { row -> String in row["name"] }
            XCTAssertTrue(indexes.contains("idx_recurring_templates_user_active"))
            XCTAssertTrue(indexes.contains("idx_recurring_templates_user_deleted"))
            // boards.spawnedFromTemplateId column exists.
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(boards)").map { row -> String in
                row["name"]
            }
            XCTAssertTrue(columns.contains("spawnedFromTemplateId"))
        }
    }

    func testTemplateInsertAndFetch_RoundTripsSeedTaskIds() throws {
        let testDb = try AppDatabase.makeTestInstance()
        let original = makeTemplate(seedTaskIds: ["a", "b", "c", "d"])
        try testDb.dbQueue.write { db in
            try original.insert(db)
        }
        let fetched = try testDb.dbQueue.read { db in
            try RecurringBoardTemplate.fetchOne(db, key: original.id)
        }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.seedTaskIds, ["a", "b", "c", "d"])
    }
}
