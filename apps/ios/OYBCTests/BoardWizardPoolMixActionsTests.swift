import XCTest
@testable import OYBC

/// BoardWizardPoolMixActionsTests — Board Sources P2 (docs/BOARD_SOURCES.md).
/// Covers the sources-native wizard actions: `pullPool` / `removeSource` /
/// `toggleTaskSelection` / `toggleSourceExclude` / `setSourceRange` /
/// `setSourceFilter`, the selection recompute, and the capacity gate. Uses
/// the SAME worked-example fixtures (pools A{x,y}, B{y,z}) as
/// `PoolMixTests`/`poolMix.test.ts` — the old flat-removal outcomes must
/// survive through per-source excludes (untoggle-persist/clear, re-pull
/// resurrection), which several tests here pin end-to-end.
final class BoardWizardPoolMixActionsTests: XCTestCase {

    // MARK: - Fixtures

    private func makeVM() -> BoardWizardViewModel {
        BoardWizardViewModel(preferences: .defaults, database: try! AppDatabase.makeTestInstance())
    }

    private func makeTask(id: String, isDeleted: Bool = false) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: "u1", title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    private func makePool(id: String, name: String? = nil, _ taskIds: [String], isDeleted: Bool = false) -> Pool {
        Pool(
            id: id, userId: "u1", name: name ?? "Pool \(id)", taskIds: taskIds,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    /// The canonical worked-example fixtures: pools A{x,y}, B{y,z}.
    private func workedExampleFixtures() -> (poolsById: [String: Pool], tasksById: [String: OYBC.Task]) {
        let poolA = makePool(id: "A", ["x", "y"])
        let poolB = makePool(id: "B", ["y", "z"])
        let tasksById = Dictionary(
            uniqueKeysWithValues: ["x", "y", "z", "w"].map { ($0, makeTask(id: $0)) }
        )
        let poolsById = Dictionary(uniqueKeysWithValues: [poolA, poolB].map { ($0.id, $0) })
        return (poolsById, tasksById)
    }

    // MARK: - pullPool

    func test_pullPool_addsSourceRowAndUnionsSupplyIntoSelection() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)

        XCTAssertEqual(vm.selectedTaskIds, ["x", "y"])
        XCTAssertEqual(vm.sources.map { $0.sourceId }, ["A"])
        XCTAssertEqual(vm.sources.first?.kind, .pool)
        // Default range = [0, all].
        XCTAssertEqual(vm.sources.first?.min, 0)
        XCTAssertNil(vm.sources.first?.max)
        // Pool-sourced additions are NOT manual; the manual-row order
        // (`poolOrder`) stays empty — source members render in the row's
        // expanded panel, not as task rows.
        XCTAssertTrue(vm.manualTaskIds.isEmpty)
        XCTAssertTrue(vm.poolOrder.isEmpty)
        // Legacy mirror.
        XCTAssertEqual(vm.pulledPoolIds, ["A"])
    }

    func test_pullPool_secondPoolUnionsAcrossOverlap() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        vm.pullPool(poolsById["B"]!, tasksById: tasksById)

        XCTAssertEqual(vm.selectedTaskIds, ["x", "y", "z"])
        XCTAssertEqual(vm.pulledPoolIds, ["A", "B"])
        XCTAssertEqual(vm.sourceCapacity, 3)
    }

    func test_pullPool_softDeletedPool_noOp() {
        let vm = makeVM()
        var (poolsById, tasksById) = workedExampleFixtures()
        poolsById["A"]?.isDeleted = true
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)

        XCTAssertTrue(vm.selectedTaskIds.isEmpty)
        XCTAssertTrue(vm.sources.isEmpty)
    }

    func test_pullPool_alreadyPulled_noOp_doesNotDuplicateSource() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)

        XCTAssertEqual(vm.sources.count, 1)
    }

    // MARK: - removeSource

    func test_removeSource_onlySource_removesWholeSupply() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        vm.removeSource(sourceId: "A")

        XCTAssertTrue(vm.selectedTaskIds.isEmpty)
        XCTAssertTrue(vm.sources.isEmpty)
    }

    func test_removeSource_taskStillSuppliedByRemainingSource_isKept() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        vm.pullPool(poolsById["B"]!, tasksById: tasksById)
        vm.removeSource(sourceId: "A")

        // y is still supplied by B → kept. x drops (only A supplied it).
        XCTAssertEqual(vm.selectedTaskIds, ["y", "z"])
        XCTAssertEqual(vm.pulledPoolIds, ["B"])
    }

    func test_removeSource_manualTaskNeverRemoved() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        vm.manualTaskIds.insert("x")
        vm.recomputeSelectionFromSources()
        vm.removeSource(sourceId: "A")

        XCTAssertEqual(vm.selectedTaskIds, ["x"])
    }

    func test_removeSource_clearsCenterMarkAndStagedEditsForDroppedRows() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        vm.centerTaskId = "x"
        vm.stagedEdits["x"] = TaskEditPatch(title: "Renamed")

        vm.removeSource(sourceId: "A")

        XCTAssertNil(vm.centerTaskId)
        XCTAssertNil(vm.stagedEdits["x"])
    }

    /// The doc's worked example, end-to-end through the sources actions:
    /// pull A+B, deselect y (→ excluded on BOTH supplying sources), remove
    /// B → y stays suppressed (A's exclude persists); remove A too → no
    /// sources left; re-pull A → a FRESH source row with no excludes → y
    /// is back. Observable outcomes match the old flat-removal model
    /// exactly (per-source excludes reproduce untoggle-persist/clear).
    func test_workedExample_pullBothRemoveY_removeBThenA_repullA() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        vm.pullPool(poolsById["B"]!, tasksById: tasksById)
        vm.manualTaskIds.insert("w")
        vm.recomputeSelectionFromSources()

        vm.toggleTaskSelection("y") // deselect → exclude everywhere
        XCTAssertEqual(vm.removedTaskIds, ["y"]) // legacy mirror
        XCTAssertEqual(vm.selectedTaskIds, ["x", "z", "w"])

        vm.removeSource(sourceId: "B")
        // y still excluded on A → stays suppressed.
        XCTAssertFalse(vm.selectedTaskIds.contains("y"))
        XCTAssertEqual(vm.pulledPoolIds, ["A"])

        vm.removeSource(sourceId: "A")
        XCTAssertTrue(vm.removedTaskIds.isEmpty)
        XCTAssertTrue(vm.pulledPoolIds.isEmpty)

        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        // The fresh pull carries no excludes — y is back.
        XCTAssertTrue(vm.selectedTaskIds.contains("y"))
    }

    // MARK: - toggleTaskSelection

    func test_toggleTaskSelection_select_marksManualAndOrders() {
        let vm = makeVM()
        vm.toggleTaskSelection("m")
        XCTAssertTrue(vm.manualTaskIds.contains("m"))
        XCTAssertEqual(vm.poolOrder, ["m"])
        XCTAssertTrue(vm.selectedTaskIds.contains("m"))
    }

    func test_toggleTaskSelection_deselect_clearsManualMark() {
        let vm = makeVM()
        vm.toggleTaskSelection("m")
        vm.toggleTaskSelection("m") // remove
        XCTAssertFalse(vm.manualTaskIds.contains("m"))
        XCTAssertFalse(vm.selectedTaskIds.contains("m"))
        XCTAssertTrue(vm.poolOrder.isEmpty)
    }

    func test_toggleTaskSelection_deselectSourceSuppliedTask_excludesFromEverySupplier() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        vm.pullPool(poolsById["B"]!, tasksById: tasksById)

        vm.toggleTaskSelection("y") // supplied by both A and B
        XCTAssertFalse(vm.selectedTaskIds.contains("y"))
        XCTAssertEqual(vm.sources[0].excludedTaskIds, ["y"])
        XCTAssertEqual(vm.sources[1].excludedTaskIds, ["y"])
    }

    func test_toggleTaskSelection_reselectAfterExclude_manualWins() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        vm.toggleTaskSelection("x") // deselect → excluded on A
        XCTAssertFalse(vm.selectedTaskIds.contains("x"))

        vm.toggleTaskSelection("x") // re-add by hand
        // Manual wins over the (persisting) exclude — resolveMix's rule.
        XCTAssertTrue(vm.selectedTaskIds.contains("x"))
        XCTAssertTrue(vm.manualTaskIds.contains("x"))
        XCTAssertEqual(vm.sources[0].excludedTaskIds, ["x"])
    }

    // MARK: - Excludes / ranges / filter

    func test_toggleSourceExclude_singleSourceScope() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById)
        vm.pullPool(poolsById["B"]!, tasksById: tasksById)

        vm.toggleSourceExclude(sourceId: "A", taskId: "y")
        // y is excluded on A only — B still supplies it → stays selected.
        XCTAssertTrue(vm.selectedTaskIds.contains("y"))
        XCTAssertEqual(vm.sources[0].excludedTaskIds, ["y"])
        XCTAssertTrue(vm.sources[1].excludedTaskIds.isEmpty)

        vm.toggleSourceExclude(sourceId: "B", taskId: "y")
        XCTAssertFalse(vm.selectedTaskIds.contains("y"))

        vm.toggleSourceExclude(sourceId: "A", taskId: "y") // UNDO on A
        XCTAssertTrue(vm.selectedTaskIds.contains("y"))
    }

    func test_setSourceRange_clampsMinToAvailableAndRequired() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById) // available 2

        vm.setSourceRange(sourceId: "A", min: 99, max: nil)
        XCTAssertEqual(vm.sources[0].min, 2) // clamped to available

        vm.setSourceRange(sourceId: "A", min: 1, max: 0)
        XCTAssertEqual(vm.sources[0].min, 1)
        XCTAssertEqual(vm.sources[0].max, 1) // max never below min
    }

    func test_excludeReclampsMin() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById) // {x, y}
        vm.setSourceRange(sourceId: "A", min: 2, max: nil)

        vm.toggleSourceExclude(sourceId: "A", taskId: "y") // available → 1
        XCTAssertEqual(vm.sources[0].min, 1)
    }

    func test_capacity_respectsNumericMax() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool(poolsById["A"]!, tasksById: tasksById) // 2 available
        vm.pullPool(poolsById["B"]!, tasksById: tasksById) // +z (y overlaps)
        XCTAssertEqual(vm.sourceCapacity, 3) // unique {x,y,z}

        vm.setSourceRange(sourceId: "B", min: 0, max: 1)
        // Bound = 2 (A) + 1 (B) = 3, unique = 3 → still 3; cap A too:
        vm.setSourceRange(sourceId: "A", min: 0, max: 1)
        XCTAssertEqual(vm.sourceCapacity, 2)
    }

    // MARK: - pullBoard (board-kind sources)

    private func seedBoardWithTasks(
        _ db: AppDatabase, boardId: String, name: String, taskIds: [String]
    ) throws {
        let now = "2026-01-01T00:00:00.000Z"
        let boardDict: [String: Any] = [
            "id": boardId, "userId": "u1", "name": name,
            "status": "active", "boardSize": 3, "timeframe": "daily",
            "startDate": now, "endDate": now,
            "centerSquareType": "none", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ]
        let board = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: boardDict)
        )
        try db.write { grdb in
            // boards.userId is a real FK — seed the owning user first.
            try User(
                id: "u1", email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
            ).insert(grdb)
            try board.insert(grdb)
            for (i, taskId) in taskIds.enumerated() {
                try makeTask(id: taskId).insert(grdb)
                try BoardTask(
                    id: "bt-\(taskId)", boardId: boardId, taskId: taskId,
                    row: i / 3, col: i % 3, isCenter: false,
                    createdAt: now, updatedAt: now,
                    lastSyncedAt: nil, version: 1, isDeleted: false
                ).insert(grdb)
            }
        }
    }

    func test_pullBoard_addsBoardSourceWithPlacedSupply() throws {
        let db = try AppDatabase.makeTestInstance()
        let vm = BoardWizardViewModel(preferences: .defaults, database: db)
        try seedBoardWithTasks(db, boardId: "b1", name: "Weekday Core", taskIds: ["bt1", "bt2", "bt3"])

        vm.pullBoard(boardId: "b1")

        XCTAssertEqual(vm.sources.map { $0.sourceId }, ["b1"])
        XCTAssertEqual(vm.sources.first?.kind, .board)
        XCTAssertEqual(vm.sources.first?.filter, .all)
        XCTAssertEqual(vm.selectedTaskIds, ["bt1", "bt2", "bt3"])
        XCTAssertEqual(vm.supplyInfoBySourceId["b1"]?.displayName, "Weekday Core")
        // Board sources are NOT in the legacy poolIds mirror.
        XCTAssertTrue(vm.pulledPoolIds.isEmpty)
    }

    func test_pullBoard_missingBoard_noOp() {
        let vm = makeVM()
        vm.pullBoard(boardId: "ghost")
        XCTAssertTrue(vm.sources.isEmpty)
        XCTAssertTrue(vm.selectedTaskIds.isEmpty)
    }

    func test_boardSource_todoFilter_dropsNothingWhenNoEvents() throws {
        let db = try AppDatabase.makeTestInstance()
        let vm = BoardWizardViewModel(preferences: .defaults, database: db)
        try seedBoardWithTasks(db, boardId: "b1", name: "Weekday Core", taskIds: ["bt1", "bt2"])
        vm.pullBoard(boardId: "b1")

        vm.setSourceFilter(sourceId: "b1", filter: .todo)
        // No completions seeded → nothing is done → supply unchanged.
        XCTAssertEqual(vm.selectedTaskIds, ["bt1", "bt2"])
        XCTAssertEqual(vm.availableCount(forSourceId: "b1"), 2)
    }
}
