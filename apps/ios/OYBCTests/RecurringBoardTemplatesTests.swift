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

    // MARK: - F3: dependency-ordered spawn (twin of the shared TS describe)

    private func pullingTemplate(_ id: String, _ timeframe: Timeframe, from boardIds: [String] = []) -> RecurringBoardTemplate {
        var t = makeTemplate(id: id, timeframe: timeframe)
        if !boardIds.isEmpty {
            t.sources = boardIds.map { BoardSource(sourceId: $0, kind: .board) }
        }
        return t
    }

    /// A previous (ended) instance of `templateId`'s series — the id a source row stored.
    private func prevInstance(_ id: String, series templateId: String?) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": "u1", "name": id, "status": "active",
            "boardSize": 3, "timeframe": "daily",
            "startDate": "2026-08-01T00:00:00.000", "endDate": "2026-08-01T23:59:59.999",
            "centerSquareType": "free", "isRandomized": false,
            "totalTasks": 8, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-08-01T00:00:00.000", "updatedAt": "2026-08-01T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        if let templateId { dict["spawnedFromTemplateId"] = templateId }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    func testF3_MonthlyPullingWeeklySeries_SpawnsAfterWeekly() {
        let pending = findTemplatesPendingSpawn(
            templates: [pullingTemplate("M", .monthly, from: ["w-prev"]), pullingTemplate("W", .weekly)],
            boards: [prevInstance("w-prev", series: "W")],
            weekStartDay: "monday",
            now: now(2026, 9, 1)
        )
        XCTAssertEqual(pending.map { $0.template.id }, ["W", "M"])
    }

    func testF3_SameTierLaterIndexSource_SpawnsFirst() {
        let pending = findTemplatesPendingSpawn(
            templates: [pullingTemplate("A", .daily, from: ["b-prev"]), pullingTemplate("B", .daily)],
            boards: [prevInstance("b-prev", series: "B")],
            weekStartDay: "monday",
            now: now(2026, 9, 7)
        )
        XCTAssertEqual(pending.map { $0.template.id }, ["B", "A"])
    }

    func testF3_UnrelatedAndOneOffSource_KeepParentsFirst() {
        let pending = findTemplatesPendingSpawn(
            templates: [
                pullingTemplate("d1", .daily, from: ["one-off"]),
                pullingTemplate("w1", .weekly),
                pullingTemplate("m1", .monthly),
            ],
            boards: [prevInstance("one-off", series: nil)],
            weekStartDay: "monday",
            now: now(2026, 9, 7)
        )
        XCTAssertEqual(pending.map { $0.template.id }, ["m1", "w1", "d1"])
    }

    func testF3_Cycle_FallsBackToParentsFirst() {
        let pending = findTemplatesPendingSpawn(
            templates: [
                pullingTemplate("A", .daily, from: ["b-prev"]),
                pullingTemplate("B", .daily, from: ["a-prev"]),
                pullingTemplate("M", .monthly),
            ],
            boards: [prevInstance("a-prev", series: "A"), prevInstance("b-prev", series: "B")],
            weekStartDay: "monday",
            now: now(2026, 9, 7)
        )
        XCTAssertEqual(pending.map { $0.template.id }, ["M", "A", "B"])
    }

    func testF3_SelfReferencingSource_IsNotABlockingEdge() {
        let pending = findTemplatesPendingSpawn(
            templates: [pullingTemplate("W", .weekly, from: ["w-prev"]), pullingTemplate("D", .daily)],
            boards: [prevInstance("w-prev", series: "W")],
            weekStartDay: "monday",
            now: now(2026, 9, 7)
        )
        XCTAssertEqual(pending.map { $0.template.id }, ["W", "D"])
    }

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

    // MARK: - computeRosterHealth (Board-settings list badge state)
    //
    // Sources-native (loose-ends sweep 2026-09-09; supersedes the legacy
    // `computeAttention`): the manual layer resolves against `tasksById`
    // (a deleted/missing hand-add flags `.hasDeletedTasks`), the
    // achievable pick drives `.poolTooSmall`, absent key ⇒ healthy. The
    // deeper source scenarios (board sources, ranges, families) live in
    // `RecurringBoardTemplatesMixTests`.

    private func manualResolution(_ ids: [String]) -> RecurringBoardTemplatesViewModel.TemplateSupplyResolution {
        RecurringBoardTemplatesViewModel.TemplateSupplyResolution(
            supplies: [], deadBoardSourceIds: [], manualTaskIds: ids
        )
    }

    func testRosterHealth_HealthyTemplate_NoBadge() {
        // 5×5 free center → required 24; 24 present hand-adds.
        let ids = (0..<24).map { "t\($0)" }
        let tpl = makeTemplate(seedTaskIds: ids)
        let tasksById = Dictionary(uniqueKeysWithValues: ids.map { ($0, makeTask($0)) })
        let (_, out) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [tpl.id: manualResolution(ids)],
            tasksById: tasksById
        )
        XCTAssertNil(out[tpl.id])
    }

    func testRosterHealth_AllTasksMissing_HasDeletedTasks() {
        let ids = (0..<24).map { "t\($0)" }
        let tpl = makeTemplate(seedTaskIds: ids)
        let (_, out) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [tpl.id: manualResolution(ids)],
            tasksById: [:]
        )
        XCTAssertEqual(out[tpl.id], .hasDeletedTasks)
    }

    func testRosterHealth_OneTaskMissing_HasDeletedTasks() {
        let ids = (0..<24).map { "t\($0)" }
        let tpl = makeTemplate(seedTaskIds: ids)
        let tasksById = Dictionary(uniqueKeysWithValues: ids.dropLast().map { ($0, makeTask($0)) })
        let (_, out) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [tpl.id: manualResolution(ids)],
            tasksById: tasksById
        )
        XCTAssertEqual(out[tpl.id], .hasDeletedTasks)
    }

    func testRosterHealth_UndersizePool_PoolTooSmall() {
        // 3×3 free center → required 8; only 5 present tasks.
        let ids = (0..<5).map { "s\($0)" }
        let tpl = makeTemplate(boardSize: 3, seedTaskIds: ids)
        let tasksById = Dictionary(uniqueKeysWithValues: ids.map { ($0, makeTask($0)) })
        let (_, out) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [tpl.id: manualResolution(ids)],
            tasksById: tasksById
        )
        XCTAssertEqual(out[tpl.id], .poolTooSmall)
    }

    func testRosterHealth_MixedTemplates_OnlyUnhealthyKeyed() {
        let healthyIds = (0..<24).map { "h\($0)" }
        let smallIds = (0..<4).map { "u\($0)" }
        let healthy = makeTemplate(id: "ok", seedTaskIds: healthyIds)
        let small = makeTemplate(id: "small", boardSize: 3, seedTaskIds: smallIds)
        let tasksById = Dictionary(
            uniqueKeysWithValues: (healthyIds + smallIds).map { ($0, makeTask($0)) }
        )
        let (_, out) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [healthy, small],
            resolutionByTemplateId: [
                "ok": manualResolution(healthyIds),
                "small": manualResolution(smallIds),
            ],
            tasksById: tasksById
        )
        XCTAssertNil(out["ok"])
        XCTAssertEqual(out["small"], .poolTooSmall)
    }

    // MARK: - computePoolPreview (issue #321 — card chip row)
    //
    // Mirrors `computeAttention`'s test shape: pure, static, no database.

    private func makeTitledTask(_ id: String, title: String) -> Task {
        Task(
            id: id, userId: "u1", title: title, type: .normal,
            operatorType: nil, threshold: nil, totalCompletions: 0, totalInstances: 0,
            isCompleted: false, createdAt: "2026-05-01T00:00:00.000Z",
            updatedAt: "2026-05-01T00:00:00.000Z", version: 1, isDeleted: false
        )
    }

    func testComputePoolPreview_FirstThreeInSeedOrder_NoOverflow() {
        let tpl = makeTemplate(seedTaskIds: ["a", "b", "c"])
        let live = [
            makeTitledTask("a", title: "Drink water"),
            makeTitledTask("b", title: "Read 30 min"),
            makeTitledTask("c", title: "Run 5 km"),
        ]
        let (preview, overflow) = RecurringBoardTemplatesViewModel.computePoolPreview(templates: [tpl], liveTasks: live)
        XCTAssertEqual(preview[tpl.id], ["Drink water", "Read 30 min", "Run 5 km"])
        XCTAssertNil(overflow[tpl.id])
    }

    func testComputePoolPreview_MoreThanThree_CapsAtThreeWithOverflowCount() {
        let tpl = makeTemplate(seedTaskIds: ["a", "b", "c", "d", "e"])
        let live = ["a", "b", "c", "d", "e"].map { makeTitledTask($0, title: "Task \($0)") }
        let (preview, overflow) = RecurringBoardTemplatesViewModel.computePoolPreview(templates: [tpl], liveTasks: live)
        XCTAssertEqual(preview[tpl.id], ["Task a", "Task b", "Task c"])
        XCTAssertEqual(overflow[tpl.id], 2)
    }

    func testComputePoolPreview_UnresolvedIdsAreSkipped_NotBlank() {
        // "b" has no matching live task (soft-deleted) — it should be
        // skipped entirely, not rendered as an empty-string chip, and the
        // remaining resolved ids still fill out the first-3 window.
        let tpl = makeTemplate(seedTaskIds: ["a", "b", "c", "d"])
        let live = [
            makeTitledTask("a", title: "First"),
            makeTitledTask("c", title: "Third"),
            makeTitledTask("d", title: "Fourth"),
        ]
        let (preview, overflow) = RecurringBoardTemplatesViewModel.computePoolPreview(templates: [tpl], liveTasks: live)
        XCTAssertEqual(preview[tpl.id], ["First", "Third", "Fourth"])
        XCTAssertNil(overflow[tpl.id])
    }

    func testComputePoolPreview_ZeroResolvable_NoEntry() {
        let tpl = makeTemplate(seedTaskIds: ["a", "b"])
        let (preview, overflow) = RecurringBoardTemplatesViewModel.computePoolPreview(templates: [tpl], liveTasks: [])
        XCTAssertNil(preview[tpl.id])
        XCTAssertNil(overflow[tpl.id])
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
    // Note: the following test verifies the v8 schema by reading + writing
    // through the test instance; it does not exercise `RecurringBoardSpawn`
    // itself. `RecurringBoardSpawn.spawnTemplateBoard` now takes a
    // `database:` seam, and its end-to-end path runs against an in-memory
    // instance in `BoardWizardPersistRecurringTemplateTests` (every
    // fresh-create persist spawns the current window's board).

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

    // MARK: - "Repeat this board…" (Task Pools + Recurring Boards Rework, P6)

    /// A Wednesday — `2026-06-24` — used for the cadence≠timeframe vector
    /// (a `.daily` board dated a Wednesday, repeated `.weekly` with
    /// `weekStartDay: "monday"` must key off that week's Monday, `2026-06-22`,
    /// not the Wednesday itself).
    private let wednesdayBoardStart = "2026-06-24T00:00:00.000"

    func testBuildRepeatBoardTemplateInput_CadenceEqualsTimeframe_WindowKeyMatchesBoardWindow() {
        // A .daily board repeated .daily — the cadence window IS the board's
        // own day, so the window key is just that day's start.
        let input = buildRepeatBoardTemplateInput(
            boardName: "Tuesday Focus",
            boardSize: 3,
            centerSquareType: .free,
            isRandomized: false,
            boardStartDate: wednesdayBoardStart,
            boardTaskIds: ["t1", "t2"],
            cadence: .daily,
            weekStartDay: "monday"
        )
        XCTAssertNotNil(input)
        XCTAssertEqual(input?.lastSpawnedWindowKey, "2026-06-24T00:00:00.000")
        XCTAssertEqual(input?.timeframe, .daily)
    }

    func testBuildRepeatBoardTemplateInput_CadenceDiffersFromTimeframe_WindowKeyIsCadenceWeekNotDay() {
        // The board itself is a one-off .daily board dated a Wednesday
        // (2026-06-24). Repeating it .weekly must key off that week's
        // MONDAY (2026-06-22), never the Wednesday — the load-bearing
        // assertion from docs/POOLS_RECURRING.md §Surfaces item 7.
        let input = buildRepeatBoardTemplateInput(
            boardName: "Wednesday Board",
            boardSize: 3,
            centerSquareType: .free,
            isRandomized: false,
            boardStartDate: wednesdayBoardStart,
            boardTaskIds: ["t1", "t2"],
            cadence: .weekly,
            weekStartDay: "monday"
        )
        XCTAssertNotNil(input)
        XCTAssertEqual(input?.timeframe, .weekly)
        XCTAssertEqual(input?.lastSpawnedWindowKey, "2026-06-22T00:00:00.000")
        // Never the board's own day.
        XCTAssertNotEqual(input?.lastSpawnedWindowKey, wednesdayBoardStart)
    }

    func testBuildRepeatBoardTemplateInput_FieldShape() {
        let input = buildRepeatBoardTemplateInput(
            boardName: "My Board",
            boardSize: 5,
            centerSquareType: .none,
            isRandomized: true,
            boardStartDate: "2026-06-24T00:00:00.000",
            boardTaskIds: ["a", "b", "c"],
            cadence: .monthly,
            weekStartDay: "sunday"
        )
        XCTAssertNotNil(input)
        guard let input else { return }
        XCTAssertEqual(input.name, "My Board")
        XCTAssertEqual(input.boardSize, 5)
        XCTAssertEqual(input.centerSquareType, .none)
        XCTAssertTrue(input.isRandomized)
        XCTAssertEqual(input.manualTaskIds, ["a", "b", "c"])
        XCTAssertEqual(input.manualTaskIds, input.seedTaskIds)
        XCTAssertEqual(input.poolIds, [])
        XCTAssertEqual(input.removedTaskIds, [])
        XCTAssertTrue(input.isActive)
    }

    func testBuildRepeatBoardTemplateInput_UnparseableStartDate_ReturnsNil() {
        let input = buildRepeatBoardTemplateInput(
            boardName: "Bad Date Board",
            boardSize: 3,
            centerSquareType: .free,
            isRandomized: false,
            boardStartDate: "not-a-date",
            boardTaskIds: ["t1"],
            cadence: .daily,
            weekStartDay: "monday"
        )
        XCTAssertNil(input)
    }

    // MARK: - repeatBoardAsTemplate (integration, in-memory GRDB)

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

    private func seedOneOffBoard(
        _ db: AppDatabase,
        id: String = "board-1",
        userId: String = "u1",
        timeframe: Timeframe = .daily,
        startDate: String = "2026-06-24T00:00:00.000",
        centerSquareType: CenterSquareType = .free
    ) throws -> Board {
        let dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": "One-off Board",
            "status": BoardStatus.active.rawValue,
            "boardSize": 3,
            "timeframe": timeframe.rawValue,
            "startDate": startDate,
            "endDate": "2026-06-24T23:59:59.999",
            "centerSquareType": centerSquareType.rawValue,
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": startDate,
            "updatedAt": startDate,
            "version": 1,
            "isDeleted": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let board = try JSONDecoder().decode(Board.self, from: data)
        try db.saveBoard(board)
        return board
    }

    private func seedPlacement(
        _ db: AppDatabase,
        id: String,
        boardId: String,
        taskId: String,
        row: Int,
        col: Int,
        userId: String = "u1"
    ) throws {
        try db.saveTask(makeTask(taskId))
        let now = AppDatabase.currentTimestamp()
        try db.saveBoardTask(BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: row, col: col,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    func testRepeatBoardAsTemplate_ManualTaskIdsMatchBoardTasks() throws {
        let testDb = try AppDatabase.makeTestInstance()
        try seedUser(testDb)
        let board = try seedOneOffBoard(testDb)
        try seedPlacement(testDb, id: "bt1", boardId: board.id, taskId: "t1", row: 0, col: 0)
        try seedPlacement(testDb, id: "bt2", boardId: board.id, taskId: "t2", row: 0, col: 1)

        let template = try testDb.repeatBoardAsTemplate(
            board: board, cadence: .weekly, userId: "u1", weekStartDay: "monday",
            now: "2026-06-24T12:00:00.000"
        )

        XCTAssertNotNil(template)
        XCTAssertEqual(Set(template?.manualTaskIds ?? []), Set(["t1", "t2"]))
        XCTAssertEqual(template?.poolIds, [])
        XCTAssertEqual(template?.removedTaskIds, [])
        XCTAssertTrue(template?.isActive ?? false)
    }

    func testRepeatBoardAsTemplate_LastSpawnedWindowKey_UsesCadenceWindow_NotBoardTimeframe() throws {
        let testDb = try AppDatabase.makeTestInstance()
        try seedUser(testDb)
        // A .daily board dated Wednesday 2026-06-24, repeated .weekly.
        let board = try seedOneOffBoard(testDb, timeframe: .daily, startDate: wednesdayBoardStart)
        try seedPlacement(testDb, id: "bt1", boardId: board.id, taskId: "t1", row: 0, col: 0)

        let template = try testDb.repeatBoardAsTemplate(
            board: board, cadence: .weekly, userId: "u1", weekStartDay: "monday",
            now: "2026-06-24T12:00:00.000"
        )

        XCTAssertEqual(template?.lastSpawnedWindowKey, "2026-06-22T00:00:00.000")
        XCTAssertEqual(template?.timeframe, .weekly)
    }

    func testRepeatBoardAsTemplate_BackStampsSourceBoard() throws {
        let testDb = try AppDatabase.makeTestInstance()
        try seedUser(testDb)
        let board = try seedOneOffBoard(testDb)
        try seedPlacement(testDb, id: "bt1", boardId: board.id, taskId: "t1", row: 0, col: 0)

        let template = try testDb.repeatBoardAsTemplate(
            board: board, cadence: .daily, userId: "u1", weekStartDay: "monday",
            now: "2026-06-24T12:00:00.000"
        )

        let updatedBoard = try testDb.fetchBoard(id: board.id)
        XCTAssertEqual(updatedBoard?.spawnedFromTemplateId, template?.id)
    }

    func testRepeatBoardAsTemplate_NoDuplicateSpawnPendingImmediatelyAfter() throws {
        let testDb = try AppDatabase.makeTestInstance()
        try seedUser(testDb)
        let board = try seedOneOffBoard(testDb, timeframe: .daily, startDate: wednesdayBoardStart)
        try seedPlacement(testDb, id: "bt1", boardId: board.id, taskId: "t1", row: 0, col: 0)

        let template = try testDb.repeatBoardAsTemplate(
            board: board, cadence: .weekly, userId: "u1", weekStartDay: "monday",
            now: "2026-06-24T12:00:00.000"
        )
        guard let template else { return XCTFail("expected a template") }

        let updatedBoard = try testDb.fetchBoard(id: board.id)
        XCTAssertNotNil(updatedBoard)

        // "Now" is still within the same week the template's
        // lastSpawnedWindowKey was stamped for — no pending spawn until the
        // window rolls over.
        let referenceDate = parseISO8601Date(wednesdayBoardStart)!
        let pending = findTemplatesPendingSpawn(
            templates: [template],
            boards: [updatedBoard!],
            weekStartDay: "monday",
            now: referenceDate
        )
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - setTemplateActive (lost-update-safe pause/resume)

    /// A spawn pass bumps `lastSpawnedWindowKey` + `version` on the live
    /// row AFTER a caller captured the template (roster load / edit-mode
    /// open). The toggle must patch the live row, not the captured copy:
    /// the spawn's window key survives and the version is spawn-bump + 1.
    func testSetTemplateActive_AfterSpawnBump_KeepsWindowKeyAndBumpsLiveVersion() throws {
        let testDb = try AppDatabase.makeTestInstance()
        let captured = makeTemplate(lastSpawnedWindowKey: "2026-05-06", isActive: true)
        try testDb.dbQueue.write { db in try captured.insert(db) }

        // Simulated spawn bump on the live row (what spawnRecurringBoard does).
        try testDb.dbQueue.write { db in
            var live = try XCTUnwrap(RecurringBoardTemplate.fetchOne(db, key: captured.id))
            live.lastSpawnedWindowKey = "2026-05-07"
            live.version += 1
            try live.update(db)
        }

        let now = "2026-05-07T12:00:00.000Z"
        let written = try testDb.setTemplateActive(id: captured.id, isActive: false, now: now)
        XCTAssertNotNil(written)

        let stored = try XCTUnwrap(testDb.dbQueue.read { db in
            try RecurringBoardTemplate.fetchOne(db, key: captured.id)
        })
        XCTAssertFalse(stored.isActive)
        XCTAssertEqual(stored.lastSpawnedWindowKey, "2026-05-07")
        XCTAssertEqual(stored.version, 3, "live version (2) + 1, not captured (1) + 1")
        XCTAssertEqual(stored.updatedAt, now)

        // The enqueued payload carries the live fields too, so the push
        // doesn't revert the spawn server-side.
        let rows = try testDb.fetchPendingSyncItems().filter {
            $0.entityType == "recurringBoardTemplates" && $0.entityId == captured.id
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.operationType, .update)
        let payload = try XCTUnwrap(rows.first?.payload)
        XCTAssertTrue(payload.contains("2026-05-07\""), "payload: \(payload)")
        XCTAssertFalse(payload.contains("2026-05-06"), "payload: \(payload)")
    }

    /// Already at the requested value (e.g. a pulled pause) → no write,
    /// no version bump, no sync item.
    func testSetTemplateActive_AlreadyAtValue_IsNoOp() throws {
        let testDb = try AppDatabase.makeTestInstance()
        let tpl = makeTemplate(isActive: false)
        try testDb.dbQueue.write { db in try tpl.insert(db) }

        let written = try testDb.setTemplateActive(
            id: tpl.id, isActive: false, now: "2026-05-07T12:00:00.000Z"
        )
        XCTAssertNil(written)
        let stored = try XCTUnwrap(testDb.dbQueue.read { db in
            try RecurringBoardTemplate.fetchOne(db, key: tpl.id)
        })
        XCTAssertEqual(stored.version, 1)
        XCTAssertTrue(try testDb.fetchPendingSyncItems().isEmpty)
    }

    /// A soft-deleted (tombstoned) template is never resurrected / bumped;
    /// a missing id is a no-op.
    func testSetTemplateActive_DeletedOrMissing_IsNoOp() throws {
        let testDb = try AppDatabase.makeTestInstance()
        let tpl = makeTemplate(isActive: true, isDeleted: true)
        try testDb.dbQueue.write { db in try tpl.insert(db) }

        XCTAssertNil(try testDb.setTemplateActive(id: tpl.id, isActive: false, now: "2026-05-07T12:00:00.000Z"))
        XCTAssertNil(try testDb.setTemplateActive(id: "nope", isActive: false, now: "2026-05-07T12:00:00.000Z"))
        let stored = try XCTUnwrap(testDb.dbQueue.read { db in
            try RecurringBoardTemplate.fetchOne(db, key: tpl.id)
        })
        XCTAssertEqual(stored.version, 1)
        XCTAssertTrue(stored.isActive)
        XCTAssertTrue(try testDb.fetchPendingSyncItems().isEmpty)
    }
}
