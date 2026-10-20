import XCTest
import GRDB
@testable import OYBC

/// The throwaway sandbox databases behind lessons 2 (pools) and 3 (Sample week):
/// they are seeded as the handoff lists, the lesson 3 script behaves as written
/// (the first Bingo lands on Tidy desk, not earlier), and nothing a sandbox does
/// reaches another database.
@MainActor
final class TutorialSandboxTests: XCTestCase {

    private let userId = "u1"

    private func makeUser() -> User {
        let now = AppDatabase.currentTimestamp()
        return User(
            id: userId, email: "t@example.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    // MARK: - Lesson 2 — pools

    func test_createBoardSandbox_hasTheThreeSuppliedPools() throws {
        let sandbox = try AppDatabase.seedTutorialSandbox(lesson: .createBoard, user: makeUser())
        let pools = try sandbox.database.fetchPools(userId: userId)
        XCTAssertEqual(pools.map(\.name).sorted(), ["Fitness", "Home", "Reading"])
        let counts = Dictionary(uniqueKeysWithValues: pools.map { ($0.name, $0.taskIds.count) })
        XCTAssertEqual(counts, ["Fitness": 9, "Reading": 6, "Home": 8])
        // Every pool member is a real, resolvable, unplaced task.
        let tasks = try sandbox.database.fetchTasks(userId: userId)
        XCTAssertEqual(tasks.count, 23)
        let ids = Set(tasks.map(\.id))
        XCTAssertTrue(pools.allSatisfy { $0.taskIds.allSatisfy(ids.contains) })
        XCTAssertTrue(try sandbox.database.fetchBoards(userId: userId).isEmpty, "Your boards are not used in the tutorial")
        XCTAssertNil(sandbox.sampleBoardId)
        XCTAssertNotNil(try sandbox.database.fetchUser(id: userId), "userId-scoped queries need the real uid's row")
    }

    // MARK: - Lesson 3 — Sample week

    func test_sampleWeek_startsAtThreeOfNineWithReadAtTwelveOfTwenty() throws {
        let sandbox = try AppDatabase.seedTutorialSandbox(lesson: .completeBoard, user: makeUser())
        let boardId = try XCTUnwrap(sandbox.sampleBoardId)
        let board = try XCTUnwrap(sandbox.database.fetchBoard(id: boardId))
        XCTAssertEqual(board.name, "Sample week")
        XCTAssertEqual(board.boardSize, 3)
        XCTAssertEqual(board.timeframe, .weekly)
        XCTAssertEqual(board.centerSquareType, .none)
        XCTAssertEqual(board.status, .active)
        XCTAssertEqual(board.completedTasks, 3, "3/9 done at the start (Water plants, Walk, Cook dinner)")
        XCTAssertEqual(board.linesCompleted, 0, "no Bingo before the lesson reaches it")

        // The window contains now, so the events count.
        let start = try XCTUnwrap(parseISO8601Date(board.startDate))
        let end = try XCTUnwrap(parseISO8601Date(try XCTUnwrap(board.endDate)))
        XCTAssertTrue(start <= Date() && Date() <= end)

        let placements = try sandbox.database.fetchBoardTasks(boardId: boardId)
        XCTAssertEqual(placements.count, 9)
        let tasks = Dictionary(uniqueKeysWithValues: try sandbox.database.fetchTasks(userId: userId).map { ($0.id, $0) })
        let byTitle = Dictionary(uniqueKeysWithValues: placements.map { (tasks[$0.taskId]!.title, ($0, tasks[$0.taskId]!)) })
        let read = try XCTUnwrap(byTitle["Read 20 pages"]).1
        XCTAssertEqual(read.type, .counting)
        XCTAssertEqual(read.maxCount, 20)
        XCTAssertEqual(read.unit, "pages")
        XCTAssertEqual(try XCTUnwrap(byTitle["Walk 10k steps"]).1.maxCount, 10)
        // The script's anchors: Stretch / Read / Tidy desk / No sugar / Journal.
        func slot(_ title: String) -> Int { let p = byTitle[title]!.0; return p.row * 3 + p.col }
        XCTAssertEqual(slot("Stretch"), TutorialCatalog.SampleSlot.stretch)
        XCTAssertEqual(slot("Read 20 pages"), TutorialCatalog.SampleSlot.read)
        XCTAssertEqual(slot("Tidy desk"), TutorialCatalog.SampleSlot.tidy)
        XCTAssertEqual(slot("No sugar"), TutorialCatalog.SampleSlot.noSugar)
        XCTAssertEqual(slot("Journal"), TutorialCatalog.SampleSlot.journal)
    }

    func test_sampleWeek_resolverReadsTheSeededEventsInTheBoardWindow() throws {
        let sandbox = try AppDatabase.seedTutorialSandbox(lesson: .completeBoard, user: makeUser())
        let boardId = try XCTUnwrap(sandbox.sampleBoardId)
        let vm = BoardPlayViewModel(boardId: boardId, userId: userId, database: sandbox.database)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == boardId && vm.boardTasks.count == 9 && !vm.allTasks.isEmpty })

        let read = try XCTUnwrap(vm.allTasks.first { $0.title == "Read 20 pages" })
        XCTAssertEqual(vm.windowedCountValue(read), 12)
        XCTAssertFalse(vm.windowedCompletedValue(read))
        let walk = try XCTUnwrap(vm.allTasks.first { $0.title == "Walk 10k steps" })
        XCTAssertEqual(vm.windowedCountValue(walk), 10)
        XCTAssertTrue(vm.windowedCompletedValue(walk))
        let doneTitles = Set(vm.allTasks.filter { $0.type == .normal && vm.windowedCompletedValue($0) }.map(\.title))
        XCTAssertEqual(doneTitles, ["Water plants", "Cook dinner"], "Call mom starts undone (owner: one line at the Bingo)")
    }

    /// The scripted lesson: Stretch (4 of 9), Read to 22/20 (5 of 9) — neither
    /// closes a line — then Tidy desk closes exactly ONE line, the middle row
    /// (6 of 9), and Call mom + Journal + No sugar finish the board.
    func test_sampleWeek_scriptYieldsOneBingoOnTidyDeskAndTheGreenlogAtTheEnd() throws {
        let sandbox = try AppDatabase.seedTutorialSandbox(lesson: .completeBoard, user: makeUser())
        let db = sandbox.database
        let boardId = try XCTUnwrap(sandbox.sampleBoardId)
        let vm = BoardPlayViewModel(boardId: boardId, userId: userId, database: db)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == boardId && vm.boardTasks.count == 9 && !vm.allTasks.isEmpty })

        func placement(_ title: String) throws -> (BoardTask, Task) {
            let task = try XCTUnwrap(vm.allTasks.first { $0.title == title })
            return (try XCTUnwrap(vm.boardTasks.first { $0.taskId == task.id }), task)
        }
        func settle() { XCTAssertTrue(waitUntil { !vm.isProcessing }) }
        func board() throws -> Board { try XCTUnwrap(db.fetchBoard(id: boardId)) }

        // 3. Stretch
        vm.handleNormalTap(boardTask: try placement("Stretch").0)
        settle()
        XCTAssertEqual(try board().completedTasks, 4)
        XCTAssertEqual(try board().linesCompleted, 0)

        // 5-6. Read +10 -> 22 of 20, done
        let (readPlacement, read) = try placement("Read 20 pages")
        vm.handleCountingTap(boardTask: readPlacement, task: read, amount: 10, persistAsDefault: false)
        settle()
        XCTAssertTrue(waitUntil { vm.windowedCountValue(try! placement("Read 20 pages").1) == 22 })
        XCTAssertEqual(try board().completedTasks, 5)
        XCTAssertEqual(try board().linesCompleted, 0, "nothing closed a line before Tidy desk")

        // 9. Tidy desk
        vm.handleNormalTap(boardTask: try placement("Tidy desk").0)
        settle()
        XCTAssertEqual(try board().completedTasks, 6)
        XCTAssertEqual(try board().linesCompleted, 1, "Tidy desk closes exactly one line — the middle row")

        // 10. Call mom + Journal + No sugar
        vm.handleNormalTap(boardTask: try placement("Call mom").0)
        settle()
        vm.handleNormalTap(boardTask: try placement("Journal").0)
        settle()
        XCTAssertLessThan(try board().completedTasks, 9)
        vm.handleNormalTap(boardTask: try placement("No sugar").0)
        settle()
        XCTAssertEqual(try board().completedTasks, 9)
        XCTAssertEqual(try board().status, .completed, "the Greenlog")
    }

    func test_sampleWeek_swapPickerHasSpareLibraryTasks() throws {
        let sandbox = try AppDatabase.seedTutorialSandbox(lesson: .completeBoard, user: makeUser())
        let boardId = try XCTUnwrap(sandbox.sampleBoardId)
        let placed = Set(try sandbox.database.fetchBoardTasks(boardId: boardId).map(\.taskId))
        let spare = try sandbox.database.fetchTasks(userId: userId).filter { !placed.contains($0.id) }
        XCTAssertEqual(spare.map(\.title).sorted(), AppDatabase.tutorialSpareTitles.sorted())
    }

    // MARK: - Isolation

    /// Counts every user-scoped table that holds app data.
    private func rowCounts(_ db: AppDatabase) throws -> [String: Int] {
        try db.read { conn in
            var counts: [String: Int] = [:]
            for table in ["boards", "tasks", "board_tasks", "task_events", "pools", "compound_children", "sync_queue", "recurring_board_templates"] {
                counts[table] = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return counts
        }
    }

    func test_aSandboxLessonWritesNothingToTheRealDatabase() throws {
        let real = try AppDatabase.makeTestInstance()
        try real.saveUser(makeUser())
        let before = try rowCounts(real)
        let coach = TutorialCoordinator(userId: userId, database: real)

        // Lesson 2: seed + wizard-style writes into the sandbox.
        XCTAssertTrue(coach.start(.createBoard))
        let sandbox2 = try XCTUnwrap(coach.sandboxDatabase)
        XCTAssertFalse(sandbox2 === real)
        XCTAssertTrue(sandbox2 !== AppDatabase.shared, "a lesson's injected database is never the app singleton")
        XCTAssertEqual(try rowCounts(sandbox2)["pools"], 3)
        let ts = AppDatabase.currentTimestamp()
        try sandbox2.saveTask(Task(
            id: "extra", userId: userId, title: "Extra", type: .normal,
            totalCompletions: 0, totalInstances: 0, createdAt: ts, updatedAt: ts, version: 1, isDeleted: false
        ))
        coach.leave()
        coach.stageDidDismiss()

        // Lesson 3: play the board in the sandbox.
        XCTAssertTrue(coach.start(.completeBoard))
        let sandbox3 = try XCTUnwrap(coach.sandboxDatabase)
        let boardId = try XCTUnwrap(coach.session?.sampleBoardId)
        let vm = BoardPlayViewModel(boardId: boardId, userId: userId, database: sandbox3)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == boardId && vm.boardTasks.count == 9 })
        vm.handleNormalTap(boardTask: try XCTUnwrap(vm.boardTasks.first))
        XCTAssertTrue(waitUntil { !vm.isProcessing })
        XCTAssertGreaterThan(try rowCounts(sandbox3)["board_tasks"] ?? 0, 0)
        XCTAssertTrue(sandbox3 !== AppDatabase.shared)
        coach.leave()
        coach.stageDidDismiss()

        XCTAssertEqual(try rowCounts(real), before, "no board, task, pool, event or sync item reached the real database")
    }

    func test_lessonOneIsTheOnlyLessonWithoutASandbox() throws {
        let real = try AppDatabase.makeTestInstance()
        try real.saveUser(makeUser())
        let coach = TutorialCoordinator(userId: userId, database: real)
        XCTAssertTrue(coach.start(.createTask))
        XCTAssertNil(coach.sandboxDatabase, "lesson 1 writes the two real tasks to the user's own library")
        coach.leave()
        coach.stageDidDismiss()
    }

    func test_eachSandboxIsIndependent() throws {
        let a = try AppDatabase.seedTutorialSandbox(lesson: .createBoard, user: makeUser())
        let b = try AppDatabase.seedTutorialSandbox(lesson: .createBoard, user: makeUser())
        try a.database.write { try $0.execute(sql: "DELETE FROM pools") }
        XCTAssertEqual(try b.database.fetchPools(userId: userId).count, 3)
    }

    func test_arrivalStoreUsesAThrowawaySuiteForASandbox() throws {
        let sandbox = try AppDatabase.makeTutorialSandbox()
        // Only the app singleton takes the standard store; a sandbox gets the
        // throwaway suite.
        let sandboxStore = CounterArrivalStore.forDatabase(sandbox)
        sandboxStore.save(boardId: "tut-board", snapshot: ["t": 1])
        XCTAssertEqual(sandboxStore.lastSeen(boardId: "tut-board"), ["t": 1])
        XCTAssertEqual(CounterArrivalStore().lastSeen(boardId: "tut-board"), [:], "the user's own store is untouched")
        UserDefaults(suiteName: CounterArrivalStore.tutorialSuiteName)?
            .removePersistentDomain(forName: CounterArrivalStore.tutorialSuiteName)
    }
}
