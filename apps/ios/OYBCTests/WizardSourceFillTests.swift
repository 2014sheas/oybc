import GRDB
import XCTest

@testable import OYBC

/// Regression suite for the owner's 2026-10-21 report (a one-off 3×3 board
/// pulling 0–4 "not done" squares from a 3×3 daily board plus five hand-added
/// tasks previewed with an empty square; two tasks tied to one shared
/// counter shared a board; a board row's counts ignored excludes).
///
/// Every scenario drives the REAL wizard path — `buildWizardPlacement` over
/// a pulled `BoardWizardViewModel` — and pins the invariant the fix restores:
/// **gate passed ⇒ every square fills**, with at most one task per counter
/// relation (family OR unit task) on the board.
final class WizardSourceFillTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppDatabase.sourceClock = { parseISO8601Date("2026-09-18T09:00:00.000Z")! }
    }

    override func tearDown() {
        AppDatabase.sourceClock = { Date() }
        super.tearDown()
    }

    private let userId = "u1"
    private let now = "2026-09-18T09:00:00.000Z"
    private let sourceBoardId = "src"
    private let windowStart = "2026-09-18T00:00:00.000Z"
    private let windowEnd = "2026-09-18T23:59:59.999Z"

    // MARK: - Fixtures

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

    private func task(
        _ id: String, type: TaskType = .normal, maxCount: CountValue? = nil,
        sharedCounterId: String? = nil, countsToward: String? = nil, title: String? = nil,
        createdInWizard: Bool = false
    ) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: userId, title: title ?? "Task \(id)", type: type,
            action: type == .counting ? "Do" : nil,
            unit: type == .counting ? "reps" : nil,
            maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId,
            createdInWizard: createdInWizard,
            countsTowardCounterId: countsToward,
            countsTowardSince: countsToward == nil ? nil : now
        )
    }

    private func makeBoard(id: String) throws -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Daily", "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": Timeframe.daily.rawValue,
            "startDate": windowStart, "endDate": windowEnd,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ]
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    /// Source board squares: a linked copy `C2` of counter root `R`, a counting
    /// root `X`, a compound `K` (children k1, k2), and normals s1…s6 — s6 is
    /// DONE in the window (a completion event), so "not done" supplies 8.
    private let placed = ["C2", "s1", "s2", "s3", "s4", "X", "K", "s5", "s6"]

    private func seed() throws -> AppDatabase {
        let database = try makeDb()
        let board = try makeBoard(id: sourceBoardId)
        try database.write { db in
            try board.save(db)
            // Counter root R + its linked copy C2 (placed on the source board).
            try self.task(
                "R", type: .counting, maxCount: 3, title: "go to bed before 10:30 3 times"
            ).save(db)
            try self.task(
                "C2", type: .counting, maxCount: 1, sharedCounterId: "R",
                title: "go to bed before 10:30", createdInWizard: true
            ).save(db)
            try self.task("X", type: .counting, maxCount: 5).save(db)
            try self.task("K", type: .compound).save(db)
            for child in ["k1", "k2"] { try self.task(child).save(db) }
            for (index, child) in ["k1", "k2"].enumerated() {
                try CompoundChild(
                    id: "link-\(child)", compoundTaskId: "K", childTaskId: child,
                    childIndex: index, createdAt: self.now, updatedAt: self.now,
                    lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
            for id in ["s1", "s2", "s3", "s4", "s5", "s6"] { try self.task(id).save(db) }
            // A unit task of R (counts toward it) and three fresh normals, in the library only.
            try self.task("U", countsToward: "R", title: "go to bed by 10:30").save(db)
            for id in ["n1", "n2", "n3", "n4"] { try self.task(id).save(db) }
            for (index, taskId) in self.placed.enumerated() {
                try BoardTask(
                    id: "bt-\(taskId)", boardId: self.sourceBoardId, taskId: taskId,
                    row: index / 3, col: index % 3, isCenter: false,
                    createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                    version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
            // s6 completed inside the window → excluded by the "not done" filter.
            try TaskEvent(
                id: "ev-s6", userId: self.userId, taskId: "s6", kind: .completion, delta: nil,
                occurredAt: "2026-09-18T08:00:00.000Z", boardId: self.sourceBoardId,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
        return database
    }

    private func makeVM(_ database: AppDatabase) -> BoardWizardViewModel {
        let vm = BoardWizardViewModel(preferences: .defaults, startRecurring: false, database: database)
        vm.size = 3
        vm.centerType = .none
        vm.timeframe = .daily
        vm.isRandomized = true
        return vm
    }

    private func makeLibrary(_ database: AppDatabase) throws -> TaskLibraryViewModel {
        let library = TaskLibraryViewModel(database: database)
        library.libraryTasks = try database.read { db in
            try OYBC.Task.filter(Column("isDeleted") == false).fetchAll(db)
        }
        return library
    }

    // MARK: - Helpers

    private struct Outcome {
        var nilCells = 0
        var familyCollisions = 0
        var unitCollisions = 0
    }

    /// Deals `deals` seeded previews and tallies empty cells + counter pairs.
    private func deal(_ vm: BoardWizardViewModel, _ library: TaskLibraryViewModel, deals: Int = 100, seedBase: Int = 0) -> Outcome {
        var out = Outcome()
        for seed in 0..<deals {
            let placement = buildWizardPlacement(
                controller: vm, library: library, previewRules: PreviewRulesOptions(seed: UInt32(seedBase + seed))
            )
            out.nilCells += placement.filter { $0 == nil }.count
            let cells = placement.compactMap { $0 }
            let families = cells.filter { $0.type == .counting }.map { $0.sharedCounterId ?? $0.id }
            if Set(families).count != families.count { out.familyCollisions += 1 }
            let counters = Set(families)
            if cells.contains(where: { $0.countsTowardCounterId.map { counters.contains($0) } ?? false }) {
                out.unitCollisions += 1
            }
        }
        return out
    }

    private func pulledVM(_ database: AppDatabase, _ library: TaskLibraryViewModel, max: Int? = 4) -> BoardWizardViewModel {
        let vm = makeVM(database)
        vm.refreshCounterFamilies(libraryTasks: library.libraryTasks)
        vm.pullBoard(boardId: sourceBoardId)
        vm.setSourceRange(sourceId: sourceBoardId, min: 0, max: max)
        return vm
    }

    // MARK: - Counter relations

    func test_buildCounterFamilyMap_putsAUnitTaskInItsCounterRootsFamily() {
        let map = BoardSources.buildCounterFamilyMap([
            task("R", type: .counting, maxCount: 3),
            task("C", type: .counting, maxCount: 1, sharedCounterId: "R"),
            task("U", countsToward: "R"),
            task("UC", type: .counting, maxCount: 2, countsToward: "R"),
            task("UK", type: .compound, countsToward: "R"),
            task("plain"),
        ])
        XCTAssertEqual(map, ["R": "R", "C": "R", "U": "R", "UC": "R", "UK": "R"])
    }

    /// A unit task hand-added while a member of its counter sits on the pulled
    /// board: the hand-add wins, the member is pruned, the board still fills.
    func test_unitTaskAndItsCounterNeverShareABoard() throws {
        let database = try seed()
        let library = try makeLibrary(database)
        let vm = pulledVM(database, library)
        for id in ["U", "n1", "n2", "n3", "n4"] { vm.toggleTaskSelection(id) }
        XCTAssertEqual(vm.sourceCapacity, 9)
        let outcome = deal(vm, library)
        XCTAssertEqual(outcome.nilCells, 0)
        XCTAssertEqual(outcome.unitCollisions, 0)
        XCTAssertEqual(outcome.familyCollisions, 0)
        let placement = buildWizardPlacement(controller: vm, library: library, previewRules: PreviewRulesOptions(seed: 7))
        XCTAssertTrue(placement.contains { $0?.id == "U" })
        XCTAssertFalse(placement.contains { $0?.id == "C2" })
    }

    // MARK: - Gate passed ⇒ the board fills

    /// Sub-tasks of a PENDING (deferred) compound, hand-added from the
    /// Library sheet's chips, are placed — not counted by the gate and then
    /// dropped by the placement lookup.
    func test_pendingCompoundChildrenAddedFromTheLibrarySheetArePlaced() throws {
        let database = try seed()
        let library = try makeLibrary(database)
        let vm = pulledVM(database, library)
        let parent = task("P", type: .compound, createdInWizard: true)
        let kids = [task("p1", createdInWizard: true), task("p2", createdInWizard: true)]
        let links = kids.enumerated().map { index, child in
            CompoundChild(
                id: "link-\(child.id)", compoundTaskId: "P", childTaskId: child.id,
                childIndex: index, createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            )
        }
        vm.toggleTaskSelection("P")
        vm.addPendingTask(PendingTaskPayload(task: parent, childTasks: kids, childLinks: links))
        for id in ["p1", "p2", "n1", "n2"] { vm.toggleTaskSelection(id) }
        XCTAssertEqual(vm.sourceCapacity, 9)
        XCTAssertEqual(deal(vm, library).nilCells, 0)
        let placement = buildWizardPlacement(controller: vm, library: library, previewRules: PreviewRulesOptions(seed: 3))
        XCTAssertTrue(placement.contains { $0?.id == "p1" })
        XCTAssertTrue(placement.contains { $0?.id == "p2" })
    }

    /// A task that leaves the library mid-session (a sync pull tombstoned it)
    /// leaves the gate and the deal together: the cached supply still names
    /// it, the capacity no longer counts it, the deal never places it.
    func test_aTaskDeletedMidSessionLeavesTheGateAndTheDealTogether() throws {
        let database = try seed()
        let library = try makeLibrary(database)
        let vm = pulledVM(database, library, max: nil)
        for id in ["U", "n1", "n2", "n3", "n4"] { vm.toggleTaskSelection(id) }
        // 8 not done − C2 (pruned by the hand-added unit task) + 5 hand-added.
        XCTAssertEqual(vm.sourceCapacity, 12)

        try database.write { db in
            var gone = try XCTUnwrap(OYBC.Task.fetchOne(db, key: "s3"))
            gone.isDeleted = true
            gone.deletedAt = self.now
            try gone.save(db)
        }
        library.libraryTasks = try database.read { db in
            try OYBC.Task.filter(Column("isDeleted") == false).fetchAll(db)
        }
        vm.refreshCounterFamilies(libraryTasks: library.libraryTasks)

        XCTAssertTrue(vm.selectedTaskIds.contains("s3"), "the cached supply still names the deleted square")
        XCTAssertEqual(vm.sourceCapacity, 11)
        XCTAssertEqual(deal(vm, library).nilCells, 0)
        for seed in 0..<40 {
            let placement = buildWizardPlacement(controller: vm, library: library, previewRules: PreviewRulesOptions(seed: UInt32(seed)))
            XCTAssertFalse(placement.contains { $0?.id == "s3" })
        }
    }

    /// Before the library loads nothing is restricted — the gate must not
    /// read "not loaded" as "nothing resolves".
    func test_anUnloadedLibraryRestrictsNothing() throws {
        let database = try seed()
        let library = try makeLibrary(database)
        let vm = makeVM(database)
        vm.pullBoard(boardId: sourceBoardId)
        for id in ["n1", "n2", "n3", "n4"] { vm.toggleTaskSelection(id) }
        XCTAssertTrue(vm.knownLibraryTaskIds.isEmpty)
        XCTAssertEqual(vm.sourceCapacity, 12)
        vm.refreshCounterFamilies(libraryTasks: library.libraryTasks)
        XCTAssertEqual(vm.sourceCapacity, 12)
    }

    // MARK: - Row counts after excludes

    func test_boardRowCountsFollowExcludes() {
        var source = BoardSource(sourceId: "b", kind: .board, filter: .todo)
        source.max = 4
        source.excludedTaskIds = ["t2", "t3"]
        let supply = WizardSourceSupply(
            displayName: "Daily", rawSupplyTaskIds: ["t1", "t2", "t3", "t4", "t5", "t6"], doneTaskIds: ["t6"]
        )
        XCTAssertEqual(
            RisoSourceRowView.subtitle(source: source, supply: supply, availableCount: 3),
            "3 not done · 2 excluded · 0–3 on the board"
        )
        XCTAssertEqual(RisoSourceRowView.rangeText(source: source, availableCount: 3), "0–3")
        XCTAssertEqual(RisoSourceRowView.effectiveMax(source: source, availableCount: 3), 3)

        source.filter = .all
        source.max = nil
        XCTAssertEqual(
            RisoSourceRowView.subtitle(source: source, supply: supply, availableCount: 4),
            "6 squares · 1 done · 2 excluded"
        )

        source.excludedTaskIds = []
        source.filter = .todo
        source.max = 4
        XCTAssertEqual(
            RisoSourceRowView.subtitle(source: source, supply: supply, availableCount: 5),
            "5 not done · 0–4 on the board"
        )
    }

    func test_restrictToResolvable_dropsUnresolvableIdsAndTreatsEmptyAsNotLoaded() {
        let supply = BoardSources.Supply(
            source: BoardSource(sourceId: "b", kind: .board, filter: .todo),
            supplyTaskIds: ["a", "gone", "b"], goalByTaskId: ["b": 3]
        )
        let out = BoardSources.restrictToResolvable([supply], manualTaskIds: ["m", "gone-m"], resolvableTaskIds: ["a", "b", "m"])
        XCTAssertEqual(out.supplies[0].supplyTaskIds, ["a", "b"])
        XCTAssertEqual(out.supplies[0].goalByTaskId, ["b": 3])
        XCTAssertEqual(out.manualTaskIds, ["m"])
        let untouched = BoardSources.restrictToResolvable([supply], manualTaskIds: ["m", "gone-m"], resolvableTaskIds: [])
        XCTAssertEqual(untouched.supplies[0].supplyTaskIds, ["a", "gone", "b"])
        XCTAssertEqual(untouched.manualTaskIds, ["m", "gone-m"])
    }

    // MARK: - Fuzz: random wizard sessions over a daily-board-shaped library

    /// A tiny deterministic LCG so a failing sequence can be replayed by seed.
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// Library modelled on the owner's daily board: counter roots R1–R3 whose
    /// linked copies C1–C3 sit on the source, a root X placed directly,
    /// compounds K1–K3 (K3 lifetime-complete), normals s1/s2 (s2 done in the
    /// window), plus library-only normals n1–n4, unit tasks U1→R1 / U2→R2 and
    /// a library compound L. C1 is done in the window (R1 incremented).
    private func seedFuzz() throws -> AppDatabase {
        let database = try makeDb()
        let board = try makeBoard(id: sourceBoardId)
        let placedIds = ["C1", "C2", "C3", "X", "K1", "K2", "K3", "s1", "s2"]
        try database.write { db in
            try board.save(db)
            for i in 1...3 {
                try self.task("R\(i)", type: .counting, maxCount: 3, title: "counter \(i) 3 times").save(db)
                try self.task("C\(i)", type: .counting, maxCount: 1, sharedCounterId: "R\(i)", title: "counter \(i)", createdInWizard: true).save(db)
            }
            try self.task("X", type: .counting, maxCount: 5).save(db)
            for k in ["K1", "K2", "K3", "L"] {
                var compound = self.task(k, type: .compound, createdInWizard: k != "L")
                if k == "K3" { compound.isCompleted = true }
                try compound.save(db)
                for (index, suffix) in ["a", "b"].enumerated() {
                    let childId = "\(k.lowercased())\(suffix)"
                    try self.task(childId, createdInWizard: k != "L").save(db)
                    try CompoundChild(
                        id: "link-\(childId)", compoundTaskId: k, childTaskId: childId,
                        childIndex: index, createdAt: self.now, updatedAt: self.now,
                        lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
                    ).save(db)
                }
            }
            for id in ["s1", "s2", "n1", "n2", "n3", "n4"] { try self.task(id).save(db) }
            try self.task("U1", countsToward: "R1", title: "unit of 1").save(db)
            try self.task("U2", countsToward: "R2", title: "unit of 2").save(db)
            for (index, taskId) in placedIds.enumerated() {
                try BoardTask(
                    id: "bt-\(taskId)", boardId: self.sourceBoardId, taskId: taskId,
                    row: index / 3, col: index % 3, isCenter: false,
                    createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                    version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
            try TaskEvent(
                id: "ev-s2", userId: self.userId, taskId: "s2", kind: .completion, delta: nil,
                occurredAt: "2026-09-18T08:00:00.000Z", boardId: self.sourceBoardId,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
            try TaskEvent(
                id: "ev-r1", userId: self.userId, taskId: "R1", kind: .increment, delta: 1,
                occurredAt: "2026-09-18T08:00:00.000Z", boardId: self.sourceBoardId,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
        return database
    }

    /// Random wizard sessions over a daily-board-shaped library: pull,
    /// range, filter, excludes, splits, chosen centre and library taps over
    /// roots, compounds, sub-tasks, unit tasks and same-Task duplicates
    /// (re-taps included). Pins: gate passed ⇒ no empty cell, no two tasks of
    /// one counter relation on the board.
    func test_fuzz_gatePassedImpliesEveryCellFilledAndOneTaskPerCounter() throws {
        let database = try seedFuzz()
        let library = try makeLibrary(database)
        let tappable = ["R1", "R2", "R3", "X", "K1", "K2", "K3", "s1", "s2", "n1", "n2", "n3", "n4",
                        "U1", "U2", "L", "k1a", "k1b", "k2a", "k2b", "k3a", "k3b", "la", "lb"]
        let placedIds = ["C1", "C2", "C3", "X", "K1", "K2", "K3", "s1", "s2"]
        var passed = 0
        for seed in 0..<500 {
            var rng = LCG(state: UInt64(seed) &+ 17)
            let vm = makeVM(database)
            vm.refreshCounterFamilies(libraryTasks: library.libraryTasks)
            let opCount = Int.random(in: 6...14, using: &rng)
            let pullAt = Int.random(in: 0..<opCount, using: &rng)
            for step in 0..<opCount {
                if step == pullAt {
                    vm.pullBoard(boardId: sourceBoardId)
                    let maxes: [Int?] = [3, 4, 4, 5, nil]
                    vm.setSourceRange(sourceId: sourceBoardId, min: 0, max: maxes[Int.random(in: 0..<maxes.count, using: &rng)])
                    continue
                }
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<6:
                    let id = tappable[Int.random(in: 0..<tappable.count, using: &rng)]
                    if id.hasPrefix("R"), Bool.random(using: &rng), let root = library.libraryTasks.first(where: { $0.id == id }) {
                        _ = vm.setPlacementParams(taskId: id, PlacementParamsDraft.forCounterGoal(2, root: root), typed: false)
                    }
                    vm.toggleTaskSelection(id)
                case 6:
                    guard !vm.sources.isEmpty else { continue }
                    vm.setSourceFilter(sourceId: sourceBoardId, filter: Bool.random(using: &rng) ? .todo : .all)
                case 7:
                    guard !vm.sources.isEmpty else { continue }
                    vm.toggleSourceExclude(sourceId: sourceBoardId, taskId: placedIds[Int.random(in: 0..<placedIds.count, using: &rng)])
                case 8:
                    guard !vm.sources.isEmpty else { continue }
                    vm.setMemberSplit(sourceId: sourceBoardId, taskId: Bool.random(using: &rng) ? "K1" : "K2", split: true)
                default:
                    if let center = vm.manualTaskIds.sorted().first, Bool.random(using: &rng) {
                        vm.centerType = .chosen
                        vm.setCenterTaskId(center)
                    }
                }
            }
            if vm.sources.isEmpty { vm.pullBoard(boardId: sourceBoardId) }
            let centerOK = vm.centerType != .chosen || (vm.centerTaskId.map { vm.selectedTaskIds.contains($0) } ?? false)
            guard vm.sourceCapacity >= vm.tasksRequired, centerOK else { continue }
            passed += 1
            let outcome = deal(vm, library, deals: 8, seedBase: seed * 100)
            XCTAssertEqual(outcome.nilCells, 0, "seed \(seed): a gate-passed session left a square empty")
            XCTAssertEqual(outcome.familyCollisions, 0, "seed \(seed): two members of one counter on the board")
            XCTAssertEqual(outcome.unitCollisions, 0, "seed \(seed): a unit task beside its counter")
        }
        XCTAssertGreaterThan(passed, 100, "the fuzz must exercise gate-passed sessions")
    }
}
