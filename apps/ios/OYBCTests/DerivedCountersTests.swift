import XCTest
import GRDB
@testable import OYBC

/// Seam tests for Board Sources §Member rules — the iOS write half in
/// `AppDatabase+DerivedCounters.swift` (TASK_WINDOW_REWORK slice 3b). Swift
/// twin of `apps/web/src/db/operations/__tests__/derivedCounters.test.ts`.
///
/// Covers:
///   1. **Plan** — a rule-governed member becomes a PLACEMENT PARAMETER
///      (`targetOverride` / `childTargets`) on its own `board_tasks` row; no
///      `tasks` / `compound_children` row is minted or enqueued.
///   2. **Refresh** — `refreshDerivedBaselines` (legacy upkeep) is
///      NON-AUTHORED: it rewrites `baseline` only (no version bump, no
///      `updatedAt`, no enqueue), and returns 0 when nothing moved.
///   3. **Persist gate** — `saveWizardBoard` plans on an ACTIVE save and NOT
///      on a draft save, and a replaced centre square keeps its cell.
///   4. **Spawn** — the recurring path writes the planner's parameters, and a
///      template's frozen `manualTaskTargets` win for a hand-added member.
///   5. **Legacy rows** — a stored window-stamped derived row resolves to its
///      ROOT, its custom title riding as `titleOverride`.
final class DerivedCountersTests: XCTestCase {

    /// An ENDED board is never a source (owner ruling 2026-09-24), judged
    /// against the wall clock by default. These fixtures live on fixed dates,
    /// so the source clock is pinned inside the 2026-09-18 / week-of-09-14 source boards' window.
    override func setUp() {
        super.setUp()
        AppDatabase.sourceClock = { parseISO8601Date("2026-09-18T09:00:00.000Z")! }
    }

    override func tearDown() {
        AppDatabase.sourceClock = { Date() }
        super.tearDown()
    }

    // MARK: - Fixtures

    private let userId = "u1"
    private let boardId = "board-1"
    private let rootId = "root-1"
    /// Board start — the RB2 boundary in every vector below.
    private let windowStart = "2026-09-18T00:00:00.000Z"
    private let windowEnd = "2026-09-18T23:59:59.999Z"
    private let now = "2026-09-18T09:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let database = try AppDatabase.makeTestInstance()
        try database.write { db in
            try User(
                id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
            ).save(db)
        }
        return database
    }

    private func makeCountingTask(
        id: String,
        maxCount: CountValue? = 10,
        currentCount: CountValue = 0,
        action: String? = "Read",
        unit: String? = "pages"
    ) -> Task {
        Task(
            id: id, userId: userId, title: "Read 10 pages", type: .counting,
            action: action, unit: unit, maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, currentCount: currentCount,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
    }

    private func makeIncrementEvent(id: String, taskId: String, delta: CountValue, at occurredAt: String) -> TaskEvent {
        TaskEvent(
            id: id, userId: userId, taskId: taskId, kind: .increment, delta: delta,
            occurredAt: occurredAt, boardId: nil,
            createdAt: occurredAt, updatedAt: occurredAt, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func boardSupply(
        _ taskIds: [String],
        memberRules: [String: BoardSourceMemberRule],
        partOf: [String: String] = [:]
    ) -> BoardSources.ExpandedSupply {
        BoardSources.ExpandedSupply(
            source: BoardSource(
                sourceId: "source-board", kind: .board, min: 0, max: nil,
                excludedTaskIds: [], filter: .all, memberRules: memberRules
            ),
            supplyTaskIds: taskIds,
            partOf: partOf
        )
    }

    private var window: BoardSources.BoardWindow {
        BoardSources.BoardWindow(timeframe: .daily, startDate: windowStart, endDate: windowEnd)
    }

    /// Plan one counting member governed by `target: 4`.
    @discardableResult
    private func planOneCounter(
        _ database: AppDatabase,
        tasksById: [String: Task]
    ) throws -> [BoardSources.PlannedPlacement] {
        try database.write { db in
            try AppDatabase.planPlacements(
                db: db,
                selectedIds: [self.rootId],
                supplies: [self.boardSupply([self.rootId], memberRules: [self.rootId: BoardSourceMemberRule(target: 4)])],
                manualTaskIds: [],
                manualTaskVary: [:],
                window: self.window,
                mode: .oneOff,
                tasksById: tasksById,
                childrenByCompoundId: [:],
                sourceWindowByTaskId: [:]
            )
        }
    }

    private func syncRows(_ database: AppDatabase, entityId: String) throws -> [SyncQueueItem] {
        try database.read { db in
            try SyncQueueItem.filter(Column("entityId") == entityId).fetchAll(db)
        }
    }

    // MARK: - 1. Plan (no rows)

    func test_plan_memberTargetBecomesAnOverride_andWritesNothing() throws {
        let database = try makeDb()
        let root = makeCountingTask(id: rootId, maxCount: 10, currentCount: 10)
        try database.write { db in try root.save(db) }
        let tasksBefore = try database.read { try Task.fetchCount($0) }

        let planned = try planOneCounter(database, tasksById: [rootId: root])

        XCTAssertEqual(planned, [BoardSources.PlannedPlacement(
            taskId: rootId, targetOverride: 4, targetKind: .discrete
        )], "the explicit member target is a parameter on the member's own placement")
        XCTAssertEqual(try database.read { try Task.fetchCount($0) }, tasksBefore, "no task row minted")
        XCTAssertEqual(try database.fetchPendingSyncItems().count, 0, "nothing enqueued")
    }

    func test_plan_continuousMemberCarriesContinuousKind() throws {
        let database = try makeDb()
        var root = makeCountingTask(id: rootId, maxCount: 10, currentCount: 0)
        root.countKind = .continuous
        try database.write { db in try root.save(db) }
        let planned = try planOneCounter(database, tasksById: [rootId: root])
        XCTAssertEqual(planned.first?.targetKind, .continuous)
        XCTAssertEqual(planned.first?.targetOverride, 4)
    }

    func test_plan_continuousMemberProRatesInTenths() throws {
        let database = try makeDb()
        var root = makeCountingTask(id: rootId, maxCount: 26.2, currentCount: 0, action: "Run", unit: "miles")
        root.title = "Run 26.2 miles"
        root.countKind = .continuous
        try database.write { db in try root.save(db) }

        let weekly = BoardSources.BoardWindow(
            timeframe: .weekly, startDate: "2026-09-14T00:00:00.000Z", endDate: "2026-09-20T23:59:59.999Z"
        )
        let planned = try database.write { db in
            try AppDatabase.planPlacements(
                db: db, selectedIds: [self.rootId],
                supplies: [self.boardSupply([self.rootId], memberRules: [:])],
                manualTaskIds: [], manualTaskVary: [:], window: weekly, mode: .oneOff,
                tasksById: [self.rootId: root], childrenByCompoundId: [:],
                sourceWindowByTaskId: [self.rootId: BoardSources.BoardWindow(timeframe: .monthly)]
            )
        }
        // ceil(26.2 × 7 / 30 = 6.113) to the 0.1 step — a whole-kind ceil would give 7.
        XCTAssertEqual(planned.first?.targetOverride, 6.2)
        XCTAssertEqual(planned.first?.targetKind, .continuous)
        let bt = BoardTask(
            id: "bt", boardId: boardId, taskId: rootId, row: 0, col: 0, isCenter: false,
            targetOverride: planned.first?.targetOverride, targetKind: planned.first?.targetKind,
            createdAt: now, updatedAt: now, version: 1
        )
        XCTAssertEqual(PlacementParams.apply(root, placement: bt, settings: .init(task: root)).title, "Run 6.2 miles")
    }

    func test_plan_compoundPartTargetBecomesChildTargets_andWritesNothing() throws {
        let database = try makeDb()
        let compoundId = "compound-1"
        let countingChildId = "child-counting"
        let normalChildId = "child-normal"
        let compound = Task(
            id: compoundId, userId: userId, title: "Morning", description: "AM routine",
            type: .compound, operatorType: .and,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        let countingChild = makeCountingTask(id: countingChildId, maxCount: 10, currentCount: 4)
        let normalChild = Task(
            id: normalChildId, userId: userId, title: "Stretch", type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        let links = [
            CompoundChild(id: "link-0", compoundTaskId: compoundId, childTaskId: countingChildId,
                          childIndex: 0, createdAt: now, updatedAt: now, lastSyncedAt: nil,
                          version: 1, isDeleted: false, deletedAt: nil),
            CompoundChild(id: "link-1", compoundTaskId: compoundId, childTaskId: normalChildId,
                          childIndex: 1, createdAt: now, updatedAt: now, lastSyncedAt: nil,
                          version: 1, isDeleted: false, deletedAt: nil),
        ]
        try database.write { db in
            try compound.save(db)
            try countingChild.save(db)
            try normalChild.save(db)
            for link in links { try link.save(db) }
        }
        let tasksBefore = try database.read { try Task.fetchCount($0) }
        let linksBefore = try database.read { try CompoundChild.fetchCount($0) }

        let planned = try database.write { db in
            try AppDatabase.planPlacements(
                db: db,
                selectedIds: [compoundId],
                supplies: [self.boardSupply(
                    [compoundId],
                    memberRules: [compoundId: BoardSourceMemberRule(
                        parts: [countingChildId: BoardSourcePartRule(target: 3)]
                    )]
                )],
                manualTaskIds: [],
                manualTaskVary: [:],
                window: self.window,
                mode: .oneOff,
                tasksById: [compoundId: compound, countingChildId: countingChild, normalChildId: normalChild],
                childrenByCompoundId: [compoundId: links],
                sourceWindowByTaskId: [:]
            )
        }

        XCTAssertEqual(planned, [BoardSources.PlannedPlacement(
            taskId: compoundId, childTargets: [PlacementChildTarget(childId: countingChildId, target: 3)]
        )], "the compound is placed as itself with the re-targeted part as a child target")
        XCTAssertEqual(try database.read { try Task.fetchCount($0) }, tasksBefore, "no derived compound / part minted")
        XCTAssertEqual(try database.read { try CompoundChild.fetchCount($0) }, linksBefore, "no derived links")
        XCTAssertEqual(try database.fetchPendingSyncItems().count, 0)
    }



    /// A window-stamped derived row whose stored `baseline` is stale.
    private func seedDerivedRow(
        _ database: AppDatabase,
        baseline: CountValue,
        startDate: String
    ) throws -> Task {
        let derived = Task(
            id: "derived-1", userId: userId, title: "Read 4 pages", type: .counting,
            action: "Read", unit: "pages", maxCount: 4,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, currentCount: 0,
            createdAt: now, updatedAt: now, version: 3, isDeleted: false,
            timeframe: .daily, startDate: startDate, endDate: windowEnd,
            sharedCounterId: rootId, baseline: baseline, createdInWizard: true
        )
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, currentCount: 0).save(db)
            try derived.save(db)
        }
        return derived
    }

    // MARK: - 6. Persist gate (saveWizardBoard)

    private func makeBoard(id: String, status: BoardStatus, centerTaskId: String?) throws -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Today", "status": status.rawValue,
            "boardSize": 3, "timeframe": Timeframe.daily.rawValue,
            "startDate": windowStart, "endDate": windowEnd,
            "centerSquareType": CenterSquareType.chosen.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ]
        if let centerTaskId { dict["centerTaskId"] = centerTaskId }
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    /// Seeds a live WEEKLY source board placing `rootId`, and returns the
    /// `BoardSource` that pulls it with an explicit target of 4.
    private func seedSourceBoard(_ database: AppDatabase) throws -> BoardSource {
        let sourceBoardId = "source-board"
        let dict: [String: Any] = [
            "id": sourceBoardId, "userId": userId, "name": "This week",
            "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": Timeframe.weekly.rawValue,
            "startDate": "2026-09-14T00:00:00.000Z", "endDate": "2026-09-20T23:59:59.999Z",
            "centerSquareType": CenterSquareType.free.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ]
        let sourceBoard = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, maxCount: 10, currentCount: 0).save(db)
            try sourceBoard.save(db)
            try BoardTask(
                id: "source-bt", boardId: sourceBoardId, taskId: self.rootId,
                row: 0, col: 0, isCenter: false,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
        return BoardSource(
            sourceId: sourceBoardId, kind: .board, min: 0, max: nil,
            excludedTaskIds: [], filter: .all,
            memberRules: [rootId: BoardSourceMemberRule(target: 4)]
        )
    }

    /// The centre placement of the board being saved (3×3 → cell (1,1)).
    private func makeCentrePlacement() -> BoardTask {
        BoardTask(
            id: "bt-centre", boardId: boardId, taskId: rootId,
            row: 1, col: 1, isCenter: true,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
    }

    func test_saveWizardBoard_draftSavePlansNothing() throws {
        let database = try makeDb()
        let source = try seedSourceBoard(database)
        let board = try makeBoard(id: boardId, status: .draft, centerTaskId: rootId)

        try database.saveWizardBoard(
            board: board, boardTasks: [makeCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [source], manualTaskIds: [], now: now
        )

        let placements = try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId).fetchAll(db)
        }
        XCTAssertEqual(placements.map { $0.taskId }, [rootId],
                       "a draft places its ORIGINAL member id")
        XCTAssertNil(placements.first?.targetOverride,
                     "a draft's window is still editable — no parameters are planned for it")
        XCTAssertEqual(try database.fetchBoard(id: boardId)?.centerTaskId, rootId)
    }

    func test_saveWizardBoard_activeSavePlansTheOverride_andTheCentreKeepsItsCell() throws {
        let database = try makeDb()
        let source = try seedSourceBoard(database)
        let board = try makeBoard(id: boardId, status: .active, centerTaskId: rootId)
        let tasksBefore = try database.read { try Task.fetchCount($0) }

        try database.saveWizardBoard(
            board: board, boardTasks: [makeCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [source], manualTaskIds: [], now: now
        )

        XCTAssertEqual(try database.read { try Task.fetchCount($0) }, tasksBefore, "no derived row minted")
        let placements = try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId && Column("isDeleted") == false)
                .fetchAll(db)
        }
        XCTAssertEqual(placements.count, 1)
        XCTAssertEqual(placements.first?.taskId, rootId, "the member is placed as itself")
        XCTAssertEqual(placements.first?.targetOverride, 4)
        XCTAssertEqual(placements.first?.targetKind, .discrete)
        XCTAssertEqual([placements.first?.row, placements.first?.col], [1, 1])
        XCTAssertEqual(placements.first?.isCenter, true)
        XCTAssertEqual(try database.fetchBoard(id: boardId)?.centerTaskId, rootId)
    }

    // MARK: - 7. Spawn (recurring path)

    /// Seeds a source board with the given placements and returns its id.
    private func seedSpawnSourceBoard(
        _ database: AppDatabase,
        id: String,
        timeframe: Timeframe,
        startDate: String,
        endDate: String,
        taskIds: [String]
    ) throws {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Source", "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": timeframe.rawValue,
            "startDate": startDate, "endDate": endDate,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ]
        let board = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
        try database.write { db in
            try board.save(db)
            for (index, taskId) in taskIds.enumerated() {
                try BoardTask(
                    id: "bt-\(id)-\(taskId)", boardId: id, taskId: taskId,
                    row: index / 3, col: index % 3, isCenter: false,
                    createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                    version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
        }
    }

    private func makeNormalTask(id: String) -> Task {
        Task(
            id: id, userId: userId, title: "Task \(id)", type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
    }

    /// A 2×2 NONE template (4 fillable cells), deterministic order.
    private func seedTemplate(
        _ database: AppDatabase,
        sources: [BoardSource],
        manualTaskIds: [String]
    ) throws -> RecurringBoardTemplate {
        let template = RecurringBoardTemplate(
            id: "tpl-1", userId: userId, name: "Daily", timeframe: .daily,
            boardSize: 2, centerSquareType: .none, isRandomized: false,
            seedTaskIds: [], manualTaskIds: manualTaskIds, sources: sources,
            lastSpawnedWindowKey: nil, isActive: true,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
        try database.write { db in
            for id in manualTaskIds where try Task.fetchOne(db, key: id) == nil {
                try self.makeNormalTask(id: id).save(db)
            }
            try template.save(db)
        }
        return template
    }

    private func spawn(
        _ database: AppDatabase,
        _ template: RecurringBoardTemplate,
        boardId spawnedId: String = "spawned-1"
    ) throws -> RecurringSpawnOutcome {
        try database.spawnRecurringBoard(
            PendingTemplateSpawn(
                template: template,
                windowStart: windowStart,
                windowEnd: windowEnd,
                suggestedName: "Daily — Sep 18"
            ),
            boardId: spawnedId,
            now: now
        )
    }

    func test_spawn_boardSourceCountingMemberGetsAProRatedOverride() throws {
        let database = try makeDb()
        // A WEEKLY source board carrying a goal of 35, pulled onto a DAILY
        // window: the auto target pro-rates 35 × (1 / 7) = 5.
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, maxCount: 35, currentCount: 9).save(db)
            try self.makeIncrementEvent(id: "e-before", taskId: self.rootId, delta: 9,
                                        at: "2026-09-16T08:00:00.000Z").save(db)
        }
        try seedSpawnSourceBoard(
            database, id: "src-weekly", timeframe: .weekly,
            startDate: "2026-09-14T00:00:00.000Z", endDate: "2026-09-20T23:59:59.999Z",
            taskIds: [rootId]
        )
        let template = try seedTemplate(
            database,
            sources: [BoardSource(sourceId: "src-weekly", kind: .board)],
            manualTaskIds: ["m1", "m2", "m3"]
        )

        let outcome = try spawn(database, template)
        guard case .spawned = outcome else { return XCTFail("expected a spawn, got \(outcome)") }

        let placed = try database.read { db in
            try BoardTask.filter(Column("boardId") == "spawned-1" && Column("isDeleted") == false)
                .fetchAll(db)
        }
        let member = try XCTUnwrap(placed.first { $0.taskId == rootId }, "the source member itself is placed")
        XCTAssertEqual(member.targetOverride, 5, "ceil(35 × 1 / 7) — the pro-rated auto target")
        XCTAssertEqual(member.targetKind, .discrete)
        XCTAssertEqual(try database.read { try Task.fetchOne($0, key: self.rootId) }?.maxCount, 35,
                       "the library task keeps its own goal")
    }

    /// Ruling 1 (slice 3b): a hand-added member the template froze keeps its
    /// frozen target / kind / title — it wins over the planner's result.
    func test_spawn_manualTaskTargetsLandAsThePlacementOverride() throws {
        let database = try makeDb()
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, maxCount: 35, currentCount: 0).save(db)
        }
        var template = try seedTemplate(database, sources: [], manualTaskIds: [rootId, "m1", "m2", "m3"])
        template.manualTaskTargets = [rootId: ManualTaskTarget(target: 8, kind: .discrete, title: "Eight pages")]
        try database.write { db in try template.save(db) }

        let outcome = try spawn(database, template)
        guard case .spawned = outcome else { return XCTFail("expected a spawn, got \(outcome)") }

        let placed = try database.read { db in
            try BoardTask.filter(Column("boardId") == "spawned-1" && Column("isDeleted") == false)
                .fetchAll(db)
        }
        let member = try XCTUnwrap(placed.first { $0.taskId == rootId })
        XCTAssertEqual(member.targetOverride, 8)
        XCTAssertEqual(member.targetKind, .discrete)
        XCTAssertEqual(member.titleOverride, "Eight pages")
        XCTAssertNil(placed.first { $0.taskId == "m1" }?.targetOverride, "the other members carry no parameters")
    }

    func test_spawn_splitCompoundContributesItsPartsAsCandidates() throws {
        let database = try makeDb()
        let compoundId = "compound-1"
        try database.write { db in
            try Task(
                id: compoundId, userId: self.userId, title: "Morning", type: .compound,
                operatorType: .and, totalCompletions: 0, totalInstances: 0,
                createdAt: self.now, updatedAt: self.now, version: 1, isDeleted: false
            ).save(db)
            try self.makeNormalTask(id: "part-a").save(db)
            try self.makeNormalTask(id: "part-b").save(db)
            try CompoundChild(
                id: "cl-0", compoundTaskId: compoundId, childTaskId: "part-a", childIndex: 0,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
            try CompoundChild(
                id: "cl-1", compoundTaskId: compoundId, childTaskId: "part-b", childIndex: 1,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
        try seedSpawnSourceBoard(
            // Open at the pinned source clock (2026-09-18 09:00Z) — an ENDED
            // board is never a source (owner ruling 2026-09-24).
            database, id: "src-daily", timeframe: .daily,
            startDate: "2026-09-18T00:00:00.000Z", endDate: "2026-09-18T23:59:59.999Z",
            taskIds: [compoundId]
        )
        let template = try seedTemplate(
            database,
            sources: [BoardSource(
                sourceId: "src-daily", kind: .board, min: 0, max: nil,
                excludedTaskIds: [], filter: .all,
                memberRules: [compoundId: BoardSourceMemberRule(split: true)]
            )],
            manualTaskIds: ["m1", "m2"]
        )

        let outcome = try spawn(database, template)
        guard case .spawned = outcome else { return XCTFail("expected a spawn, got \(outcome)") }

        let placed = try database.read { db in
            try BoardTask.filter(Column("boardId") == "spawned-1" && Column("isDeleted") == false)
                .fetchAll(db)
                .map { $0.taskId }
        }
        XCTAssertEqual(Set(placed), ["part-a", "part-b", "m1", "m2"],
                       "Split up contributes the PARTS as selectable squares, never the compound")
        XCTAssertFalse(placed.contains(compoundId))
    }

    // MARK: - 7. GRDB v32 — the tasks(sharedCounterId) index

    func test_migrationV32_indexesTasksSharedCounterId() throws {
        // Every window-stamped derived read filters on `sharedCounterId`, and
        // the pull runs one per affected task inside its write transaction —
        // unindexed that is a full `tasks` scan per row. The web twin has
        // always been index-backed.
        let database = try makeDb()
        let indexes: [String] = try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='tasks'"
            ).map { row in row["name"] }
        }
        XCTAssertTrue(indexes.contains("idx_tasks_shared_counter"),
                      "v32 must create idx_tasks_shared_counter; found \(indexes)")

        // And it really covers the column the reads use.
        let columns: [String] = try database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_info('idx_tasks_shared_counter')")
                .map { row in row["name"] }
        }
        XCTAssertEqual(columns, ["sharedCounterId"])
    }
    func test_migrationV46_addsTheManualTaskTargetsColumn_andRoundTripsTheField() throws {
        let database = try makeDb()
        let columns: [String] = try database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(recurring_board_templates)").map { row in row["name"] }
        }
        XCTAssertTrue(columns.contains("manualTaskTargets"), "v46 adds the column; found \(columns)")

        var template = try seedTemplate(database, sources: [], manualTaskIds: ["m1"])
        XCTAssertNil(try database.read { try RecurringBoardTemplate.fetchOne($0, key: template.id) }?.manualTaskTargets,
                     "absent on a pre-feature row")
        template.manualTaskTargets = ["m1": ManualTaskTarget(target: 3, kind: .duration, title: "Stretch")]
        try database.write { db in try template.save(db) }
        let back = try database.read { try RecurringBoardTemplate.fetchOne($0, key: template.id) }
        XCTAssertEqual(back?.manualTaskTargets, ["m1": ManualTaskTarget(target: 3, kind: .duration, title: "Stretch")])
    }

    // MARK: - 8. §Member rules (B3): the wizard's hand-added dice

    /// Seeds the counting task a hand-added member points at and returns the
    /// active board + its single (centre) placement.
    private func seedHandAddedCounter(_ database: AppDatabase) throws -> Board {
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, maxCount: 10, currentCount: 0).save(db)
        }
        return try makeBoard(id: boardId, status: .active, centerTaskId: rootId)
    }

    /// B3 threading, the decisive half: with dice on the hand-added layer the
    /// active save plans a `targetOverride` that is a ROLL inside `varyRange`,
    /// not the goal copied through. The assertion pins the range (the
    /// production rng is unseeded), and the control test below proves the
    /// parameter only appears because the dice arrived.
    func test_saveWizardBoard_handAddedDice_planARolledOverrideInsideVaryRange() throws {
        let database = try makeDb()
        let board = try seedHandAddedCounter(database)
        let tasksBefore = try database.read { try Task.fetchCount($0) }

        try database.saveWizardBoard(
            board: board, boardTasks: [makeCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [], manualTaskIds: [rootId],
            manualTaskVary: [rootId: .lot], now: now, rng: { 0 }
        )

        let range = BoardSources.varyRange(t: 10, level: .lot, goal: 10)
        let placements = try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId && Column("isDeleted") == false)
                .fetchAll(db)
        }
        XCTAssertEqual(placements.first?.taskId, rootId)
        XCTAssertEqual(placements.first?.targetOverride, range.lowerBound)
        XCTAssertNotEqual(placements.first?.targetOverride, 10)
        XCTAssertEqual(try database.read { try Task.fetchCount($0) }, tasksBefore)
    }

    // MARK: - 9. Custom counter title survives the mint (owner bug 2026-10-06)

    private let hubRootId = "hub-root"
    private let linkedId = "linked-1"

    /// Seeds a hub-born root plus the wizard-created, auto-linked member
    /// pointing at it (`sharedCounterId` set, no window stamp — the shape
    /// that is ALWAYS minted since #537), and returns the active board whose
    /// centre places the member.
    private func seedLinkedMember(_ database: AppDatabase, title: String) throws -> Board {
        try database.write { db in
            try Task(
                id: self.hubRootId, userId: self.userId, title: "Push-ups", type: .counting,
                action: "Do", unit: "push-ups", maxCount: nil,
                totalCompletions: 0, totalInstances: 0,
                isCompleted: false, currentCount: 0,
                createdAt: self.now, updatedAt: self.now, version: 1, isDeleted: false
            ).save(db)
            try Task(
                id: self.linkedId, userId: self.userId, title: title, type: .counting,
                action: "Do", unit: "push-ups", maxCount: 20,
                totalCompletions: 0, totalInstances: 0,
                isCompleted: false, currentCount: 0,
                createdAt: self.now, updatedAt: self.now, version: 1, isDeleted: false,
                sharedCounterId: self.hubRootId, createdInWizard: true
            ).save(db)
        }
        return try makeBoard(id: boardId, status: .active, centerTaskId: linkedId)
    }

    private func makeLinkedCentrePlacement() -> BoardTask {
        BoardTask(
            id: "bt-centre", boardId: boardId, taskId: linkedId,
            row: 1, col: 1, isCenter: true,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// The owner's exact path: a counting task given a CUSTOM name in the
    /// wizard, auto-linked to a shared counter and hand-added. Since slice 3b
    /// it is placed as ITSELF (no per-window copy is minted), so its stored
    /// title is what the board shows. Mirrors web `wizardBoard.test.ts`.
    func test_saveWizardBoard_handAddedLinkedCustomTitle_isPlacedAsItself() throws {
        let database = try makeDb()
        let board = try seedLinkedMember(database, title: "Morning push-ups")
        let tasksBefore = try database.read { try Task.fetchCount($0) }

        try database.saveWizardBoard(
            board: board, boardTasks: [makeLinkedCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [], manualTaskIds: [linkedId],
            manualTaskVary: [:], now: now
        )

        XCTAssertEqual(try database.read { try Task.fetchCount($0) }, tasksBefore, "no copy minted")
        let placements = try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId && Column("isDeleted") == false)
                .fetchAll(db)
        }
        XCTAssertEqual(placements.map { $0.taskId }, [linkedId])
        XCTAssertNil(placements.first?.targetOverride, "its own goal 20 is the placement's goal")
        XCTAssertEqual(try database.fetchTask(id: linkedId)?.title, "Morning push-ups")
    }

    /// Control: an AUTO title ("Do 20 push-ups" for Do / 20 / push-ups) follows
    /// the placement's rolled target — with dice on and a seeded rng the
    /// override pins the LOW end of the range, and the placement title is
    /// re-rendered at it. Pinning the low end proves the roll happened.
    func test_saveWizardBoard_handAddedLinkedAutoTitle_followsThePlacementTarget() throws {
        let database = try makeDb()
        let board = try seedLinkedMember(database, title: "Do 20 push-ups")

        try database.saveWizardBoard(
            board: board, boardTasks: [makeLinkedCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [], manualTaskIds: [linkedId],
            manualTaskVary: [linkedId: .lot], now: now, rng: { 0 }
        )

        let range = BoardSources.varyRange(t: 20, level: .lot, goal: 20)
        XCTAssertLessThan(range.lowerBound, 20, "the assertions below would be degenerate")
        let placed = try XCTUnwrap(try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId && Column("isDeleted") == false).fetchOne(db)
        })
        XCTAssertEqual(placed.taskId, linkedId)
        XCTAssertEqual(placed.targetOverride, range.lowerBound)
        let task = try XCTUnwrap(try database.fetchTask(id: linkedId))
        XCTAssertEqual(
            PlacementParams.apply(task, placement: placed).title,
            "Do \(formatCount(range.lowerBound, kind: .discrete)) push-ups"
        )
    }

    /// Control: the SAME save without dice places the member with no parameters.
    func test_saveWizardBoard_handAddedWithoutDice_writesNoParameters() throws {
        let database = try makeDb()
        let board = try seedHandAddedCounter(database)

        try database.saveWizardBoard(
            board: board, boardTasks: [makeCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [], manualTaskIds: [rootId],
            manualTaskVary: [:], now: now
        )

        let placements = try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId && Column("isDeleted") == false)
                .fetchAll(db)
        }
        XCTAssertEqual(placements.map { $0.taskId }, [rootId])
        XCTAssertNil(placements.first?.targetOverride)
    }

    // MARK: - 10. Pool-level default dice (docs/BOARD_SOURCES.md §Member rules → Pool-level defaults, 2026-10-06)

    private let dicePoolId = "pool-dice"

    /// Seeds the counting root (goal 10) plus three normal fillers inside one
    /// pool — 4 members for the 2×2 NONE template's 4 cells — with the given
    /// pool-level default dice.
    private func seedDicePool(_ database: AppDatabase, memberVary: [String: VaryLevel]) throws {
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, maxCount: 10, currentCount: 0).save(db)
            for id in ["pf1", "pf2", "pf3"] { try self.makeNormalTask(id: id).save(db) }
            try Pool(
                id: self.dicePoolId, userId: self.userId, name: "Dice pool",
                taskIds: [self.rootId, "pf1", "pf2", "pf3"], memberVary: memberVary,
                createdAt: self.now, updatedAt: self.now
            ).save(db)
        }
    }

    private func spawnedPlacements(_ database: AppDatabase) throws -> [String] {
        try database.read { db in
            try BoardTask.filter(Column("boardId") == "spawned-1" && Column("isDeleted") == false)
                .fetchAll(db)
                .map { $0.taskId }
        }
    }

    /// A pool member with no stored rule inherits the pool's default at
    /// spawn (`withEffectiveMemberRules` in the supply builder): the spawned
    /// copy is a ROLL inside `varyRange`, not the root placed as-is. Twin of
    /// web `recurringBoardSpawnMix.test.ts` "pool-level default dice".
    func test_spawn_poolDefaultDice_plansARolledTargetInsideVaryRange() throws {
        let database = try makeDb()
        try seedDicePool(database, memberVary: [rootId: .lot])
        let template = try seedTemplate(
            database, sources: [BoardSource(sourceId: dicePoolId, kind: .pool)], manualTaskIds: []
        )

        let outcome = try spawn(database, template)
        guard case .spawned = outcome else { return XCTFail("expected a spawn, got \(outcome)") }

        let range = BoardSources.varyRange(t: 10, level: .lot, goal: 10)
        XCTAssertLessThan(range.lowerBound, range.upperBound, "the range is real, not collapsed")
        let placed = try database.read { db in
            try BoardTask.filter(Column("boardId") == "spawned-1" && Column("isDeleted") == false)
                .fetchAll(db)
        }
        let member = try XCTUnwrap(placed.first { $0.taskId == self.rootId }, "the pool member itself is placed")
        // The roll may land on the goal itself (no override then); anything else is in range.
        if let target = member.targetOverride {
            XCTAssertTrue(range.contains(target),
                          "rolled target \(target) must land inside \(range.lowerBound)…\(range.upperBound)")
        }
    }

    /// Control: without a pool default (and no rule) the member is placed
    /// with no parameters.
    func test_spawn_poolWithoutDefault_placesTheMemberItself() throws {
        let database = try makeDb()
        try seedDicePool(database, memberVary: [:])
        let template = try seedTemplate(
            database, sources: [BoardSource(sourceId: dicePoolId, kind: .pool)], manualTaskIds: []
        )

        let outcome = try spawn(database, template)
        guard case .spawned = outcome else { return XCTFail("expected a spawn, got \(outcome)") }

        XCTAssertTrue(try spawnedPlacements(database).contains(rootId))
        let placed = try database.read { db in
            try BoardTask.filter(Column("boardId") == "spawned-1" && Column("taskId") == self.rootId).fetchOne(db)
        }
        XCTAssertNil(placed?.targetOverride)
    }

    /// Seeds the root (goal 10) in a pool with the given default and returns
    /// the active board whose centre places the root.
    private func seedPoolCentre(_ database: AppDatabase, memberVary: [String: VaryLevel]) throws -> Board {
        let board = try seedHandAddedCounter(database)
        try database.write { db in
            try Pool(
                id: self.dicePoolId, userId: self.userId, name: "Dice pool",
                taskIds: [self.rootId], memberVary: memberVary,
                createdAt: self.now, updatedAt: self.now
            ).save(db)
        }
        return board
    }

    /// ONE-OFF persist applies the same fallback. Seeded rng pins the LOW end
    /// of the range: the pool's `.lot` bottoms at 5. Twin of web
    /// `wizardBoard.test.ts` "pool-level default dice".
    func test_saveWizardBoard_poolDefaultDice_appliesWhenTheSourceStoresNoVary() throws {
        let database = try makeDb()
        let board = try seedPoolCentre(database, memberVary: [rootId: .lot])

        try database.saveWizardBoard(
            board: board, boardTasks: [makeCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [BoardSource(sourceId: dicePoolId, kind: .pool)],
            manualTaskIds: [], now: now, rng: { 0 }
        )

        let placed = try XCTUnwrap(try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId && Column("isDeleted") == false).fetchOne(db)
        })
        XCTAssertEqual(placed.taskId, rootId)
        XCTAssertEqual(placed.targetOverride, BoardSources.varyRange(t: 10, level: .lot, goal: 10).lowerBound)
    }

    /// A stored source `vary` ALWAYS wins over the pool default: `.little`
    /// bottoms at 8, the pool's `.lot` at 5 — told apart by value.
    func test_saveWizardBoard_poolDefaultDice_aStoredSourceVaryWins() throws {
        let database = try makeDb()
        let board = try seedPoolCentre(database, memberVary: [rootId: .lot])

        try database.saveWizardBoard(
            board: board, boardTasks: [makeCentrePlacement()], pendingTasks: [],
            isUpdate: false,
            sources: [BoardSource(
                sourceId: dicePoolId, kind: .pool, min: 0, max: nil,
                excludedTaskIds: [], filter: .all,
                memberRules: [rootId: BoardSourceMemberRule(vary: .little)]
            )],
            manualTaskIds: [], now: now, rng: { 0 }
        )

        let placed = try XCTUnwrap(try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId && Column("isDeleted") == false).fetchOne(db)
        })
        let overrideLow = BoardSources.varyRange(t: 10, level: .little, goal: 10).lowerBound
        XCTAssertNotEqual(overrideLow, BoardSources.varyRange(t: 10, level: .lot, goal: 10).lowerBound)
        XCTAssertEqual(placed.targetOverride, overrideLow)
    }
}
