import GRDB
import XCTest
@testable import OYBC

/// Board Sources §Member rules (B3, RC6) — the wizard Preview's member-rule
/// DRY RUN (`Views/CreateTab/BoardWizardPreviewDerived.swift`) and the
/// `previewRules` hook on `buildWizardPlacement`.
///
/// Swift twin of web's `previewDerived` suite. Everything runs against an
/// isolated `AppDatabase.makeTestInstance()`, which is also how the "writes
/// nothing" guarantee is checked: the dry run must leave every table at the
/// row count it found.
final class BoardWizardPreviewDerivedTests: XCTestCase {

    // MARK: - Fixtures

    private let userId = "u1"
    private let now = "2026-09-18T09:00:00.000Z"
    private let sourceBoardId = "source-board"
    private let windowStart = "2026-09-18T00:00:00.000Z"
    private let windowEnd = "2026-09-18T23:59:59.999Z"

    /// The counting member's own goal — big enough that a `.lot` roll has a
    /// 51-wide range to land in, so "two seeds differ" is not a coin flip.
    private let countingGoal = 100

    private func makeDb() throws -> AppDatabase {
        let database = try AppDatabase.makeTestInstance()
        try database.write { db in
            try User(
                id: self.userId, email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil, version: 1
            ).save(db)
        }
        return database
    }

    private func makeTask(
        _ id: String,
        type: TaskType = .normal,
        maxCount: Int? = nil
    ) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: userId, title: "Task \(id)", type: type,
            action: type == .counting ? "Run" : nil,
            unit: type == .counting ? "miles" : nil,
            maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
    }

    private func makeBoard(id: String) throws -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Source", "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": Timeframe.daily.rawValue,
            "startDate": windowStart, "endDate": windowEnd,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ]
        return try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
    }

    /// Every task the source board carries: the counting member `cnt`
    /// (goal 100), the One-square compound `C` with two counting children,
    /// and normals `n1`…`n7` so a 3×3 has nine squares to fill.
    private var normalIds: [String] { (1...7).map { "n\($0)" } }
    private var placedIds: [String] { ["cnt", "C"] + normalIds }

    /// Seeds the source board and returns an open test database.
    private func seedSourceBoard() throws -> AppDatabase {
        let database = try makeDb()
        let board = try makeBoard(id: sourceBoardId)
        try database.write { db in
            try board.save(db)
            try self.makeTask("cnt", type: .counting, maxCount: self.countingGoal).save(db)
            try self.makeTask("C", type: .compound).save(db)
            for child in ["c1", "c2"] {
                try self.makeTask(child, type: .counting, maxCount: 20).save(db)
            }
            for id in self.normalIds { try self.makeTask(id).save(db) }
            for (index, child) in ["c1", "c2"].enumerated() {
                try CompoundChild(
                    id: "link-\(child)", compoundTaskId: "C", childTaskId: child,
                    childIndex: index, createdAt: self.now, updatedAt: self.now,
                    lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
            for (index, taskId) in self.placedIds.enumerated() {
                try BoardTask(
                    id: "bt-\(taskId)", boardId: self.sourceBoardId, taskId: taskId,
                    row: index / 3, col: index % 3, isCenter: false,
                    createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                    version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
        }
        return database
    }

    /// A one-off wizard with the source board pulled, `cnt` set to the
    /// widest dice, and `C`'s first part explicitly re-targeted (which is
    /// what makes the planner mint a DERIVED COMPOUND for it).
    private func pulledVM(_ database: AppDatabase) -> BoardWizardViewModel {
        let vm = BoardWizardViewModel(
            preferences: .defaults, startRecurring: false, database: database
        )
        vm.size = 3
        vm.centerType = .none
        vm.timeframe = .daily
        vm.pullBoard(boardId: sourceBoardId)
        vm.setMemberVary(sourceId: sourceBoardId, taskId: "cnt", level: .lot)
        vm.setPartTarget(sourceId: sourceBoardId, taskId: "C", childId: "c1", target: 5)
        return vm
    }

    private func makeLibrary(_ database: AppDatabase) throws -> TaskLibraryViewModel {
        let library = TaskLibraryViewModel(database: database)
        library.libraryTasks = try database.read { db in
            try OYBC.Task.filter(Column("isDeleted") == false).fetchAll(db)
        }
        return library
    }

    /// Cell id → cell, for the non-nil cells of a placement.
    private func cells(_ placement: WizardPlacement) -> [String: OYBC.Task] {
        var out: [String: OYBC.Task] = [:]
        for case let task? in placement { out[task.id] = task }
        return out
    }

    /// The comparable shape of a placement: order, ids, titles and targets.
    private func shape(_ placement: WizardPlacement) -> [String] {
        placement.map { cell in
            guard let cell else { return "·" }
            return "\(cell.id)/\(cell.title)/\(cell.maxCount.map(String.init) ?? "-")"
        }
    }

    // MARK: - 1. Determinism (RC6 item 3)

    func test_sameSeedProducesTheIdenticalPreviewTwice() throws {
        let database = try seedSourceBoard()
        let vm = pulledVM(database)
        let library = try makeLibrary(database)

        let first = buildWizardPlacement(
            controller: vm, library: library, previewRules: PreviewRulesOptions(seed: 7)
        )
        let second = buildWizardPlacement(
            controller: vm, library: library, previewRules: PreviewRulesOptions(seed: 7)
        )

        XCTAssertEqual(shape(first), shape(second),
                       "one seed must reproduce the arrangement AND the rolls")
        XCTAssertEqual(first.count, 9)
        XCTAssertNotNil(cells(first)["cnt"]?.maxCount,
                        "the fixture must actually produce a stand-in, or this proves nothing")
    }

    // MARK: - 2. Different seeds re-roll (RC6 items 3 + 5)

    func test_differentSeedsRollDifferentTargetsWithinTheRange() throws {
        let database = try seedSourceBoard()
        let vm = pulledVM(database)
        let library = try makeLibrary(database)

        var rolled = Set<Int>()
        for seed in UInt32(0)..<UInt32(12) {
            let placement = buildWizardPlacement(
                controller: vm, library: library, previewRules: PreviewRulesOptions(seed: seed)
            )
            rolled.insert(try XCTUnwrap(cells(placement)["cnt"]?.maxCount))
        }

        XCTAssertGreaterThan(rolled.count, 1,
                             "adjacent Shuffle nonces must visibly re-roll (the LCG warm-up)")
        let range = BoardSources.varyRange(t: countingGoal, level: .lot, goal: countingGoal)
        for target in rolled {
            XCTAssertTrue(range.contains(target),
                          "\(target) escaped varyRange \(range.lowerBound)…\(range.upperBound)")
        }
    }

    // MARK: - 3. Stand-in shape (RC6 item 1)

    func test_standInKeepsTheOriginalIdAndShowsTheRolledTitleAndTarget() throws {
        let database = try seedSourceBoard()
        let vm = pulledVM(database)
        let library = try makeLibrary(database)

        let placement = buildWizardPlacement(
            controller: vm, library: library, previewRules: PreviewRulesOptions(seed: 3)
        )
        let byId = cells(placement)
        let standIn = try XCTUnwrap(byId["cnt"], "the stand-in must keep the ORIGINAL task id")
        let rolled = try XCTUnwrap(standIn.maxCount)

        let range = BoardSources.varyRange(t: countingGoal, level: .lot, goal: countingGoal)
        XCTAssertTrue(range.contains(rolled))
        XCTAssertNotEqual(standIn.title, "Task cnt",
                          "the cell must show the generated counter title, not the library one")
        XCTAssertEqual(
            standIn.title,
            TaskTitle.generateCounterTaskTitle(action: "Run", maxCount: rolled, unit: "miles"),
            "the preview title is the planner's, verbatim"
        )
        XCTAssertEqual(standIn.action, "Run")
        XCTAssertEqual(standIn.unit, "miles")
        XCTAssertEqual(standIn.currentCount, 0, "a fresh window starts at zero")
        XCTAssertEqual(standIn.baseline, 0)

        // A plain member the rules never touch is handed back untouched.
        XCTAssertEqual(byId["n1"]?.title, "Task n1")
    }

    // MARK: - 4. Derived compounds are NOT stood in (RC6 item 2)

    func test_derivedCompoundIsPlannedButTheCellKeepsTheOriginalCompound() throws {
        let database = try seedSourceBoard()
        let vm = pulledVM(database)
        let library = try makeLibrary(database)

        let placement = buildWizardPlacement(
            controller: vm, library: library, previewRules: PreviewRulesOptions(seed: 11)
        )
        let orderedIds = placement.compactMap { $0?.id }

        // The planner really does re-mint this compound — run it over the
        // SAME ids the preview just placed and confirm a derived compound
        // came out, so the assertion below proves SUPPRESSION, not absence.
        guard case .ok(let start, let end) = resolveWizardDates(controller: vm) else {
            return XCTFail("expected resolvable wizard dates")
        }
        var sourceWindowByTaskId: [String: BoardSources.BoardWindow] = [:]
        let sourceWindow = try XCTUnwrap(vm.supplyInfoBySourceId[sourceBoardId]?.sourceWindow)
        for supply in vm.expandedSupplies {
            for id in supply.supplyTaskIds {
                sourceWindowByTaskId[id] = sourceWindow
                for link in vm.childrenByCompoundId[id] ?? [] {
                    sourceWindowByTaskId[link.childTaskId] = sourceWindow
                }
            }
        }
        var tasksById: [String: OYBC.Task] = [:]
        for task in library.libraryTasks { tasksById[task.id] = task }
        let plan = BoardSources.planDerivedTasks(
            selectedIds: orderedIds,
            supplies: vm.expandedSupplies,
            manualTaskIds: Array(vm.manualTaskIds),
            manualTaskVary: vm.manualTaskVary,
            boardId: previewBoardId,
            window: BoardSources.BoardWindow(
                timeframe: vm.timeframe, startDate: start, endDate: end
            ),
            mode: .oneOff,
            tasksById: tasksById,
            childrenByCompoundId: vm.childrenByCompoundId,
            sourceWindowByTaskId: sourceWindowByTaskId,
            baselineByRootId: [:],
            rng: makePreviewRng(shuffleNonce: 11)
        )
        let derivedCompound = try XCTUnwrap(plan.derivedCompounds.first)
        XCTAssertEqual(derivedCompound.sourceCompoundId, "C")
        XCTAssertTrue(plan.placementIds.contains(derivedCompound.id),
                      "the persist path would place the DERIVED compound id")

        // …and yet the preview cell is the original compound, untouched.
        let compoundCell = try XCTUnwrap(cells(placement)["C"])
        XCTAssertEqual(compoundCell.title, "Task C")
        XCTAssertEqual(compoundCell.type, .compound)
        XCTAssertFalse(orderedIds.contains(derivedCompound.id),
                       "a derived compound id in a cell would orphan the children lookup")
    }

    // MARK: - 5. The dry run writes nothing (RC6 item 4)

    func test_theDryRunWritesNoRows() throws {
        let database = try seedSourceBoard()
        let vm = pulledVM(database)
        let library = try makeLibrary(database)

        func counts() throws -> [String: Int] {
            try database.read { db in
                [
                    "tasks": try OYBC.Task.fetchCount(db),
                    "boards": try Board.fetchCount(db),
                    "boardTasks": try BoardTask.fetchCount(db),
                    "compoundChildren": try CompoundChild.fetchCount(db),
                    "taskEvents": try TaskEvent.fetchCount(db),
                    "syncQueue": try SyncQueueItem.fetchCount(db),
                ]
            }
        }

        let before = try counts()
        XCTAssertGreaterThan(try XCTUnwrap(before["tasks"]), 0, "the fixture must be seeded")

        for seed in UInt32(0)..<UInt32(4) {
            _ = buildWizardPlacement(
                controller: vm, library: library, previewRules: PreviewRulesOptions(seed: seed)
            )
        }

        XCTAssertEqual(try counts(), before,
                       "the Preview dry run must never touch GRDB or the sync queue")
    }

    // MARK: - 6. Persist path is untouched (RC6 item 3, last sentence)

    func test_withoutPreviewRulesTheMembersAreNotStoodIn() throws {
        let database = try seedSourceBoard()
        let vm = pulledVM(database)
        let library = try makeLibrary(database)

        let placement = buildWizardPlacement(controller: vm, library: library)
        let standIn = try XCTUnwrap(cells(placement)["cnt"])

        XCTAssertEqual(standIn.title, "Task cnt",
                       "persist mints the real rows itself — it must get the raw member")
        XCTAssertEqual(standIn.maxCount, countingGoal)
    }
}
