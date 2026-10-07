import XCTest
@testable import OYBC

/// Unit tests for `ProfileHomeViewModel` (Profile reorg PR2) — the pure
/// helpers (counter recency ordering, tile-summary formatting, Getting
/// Started display selection) get full coverage without touching the DB;
/// integration tests against an injected `AppDatabase.makeTestInstance()`
/// confirm `load()` wires end to end and that "+ Log" / Undo go through the
/// shared-counter ops and drive the toast state.
@MainActor
final class ProfileHomeViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func task(
        id: String,
        type: TaskType = .counting,
        title: String = "Task",
        sharedCounterId: String? = nil,
        currentCount: CountValue? = nil,
        action: String? = "Do",
        unit: String? = "reps",
        createdAt: String = "2026-01-01T00:00:00.000",
        isCounter: Bool = false
    ) -> Task {
        Task(
            id: id, userId: "u1", title: title, type: type,
            action: action, unit: unit,
            totalCompletions: 0, totalInstances: 0,
            currentCount: currentCount,
            createdAt: createdAt, updatedAt: createdAt,
            version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId,
            baseline: sharedCounterId != nil ? 0 : nil,
            isCounter: isCounter
        )
    }

    private func event(
        id: String, taskId: String,
        occurredAt: String, createdAt: String? = nil
    ) -> TaskEvent {
        TaskEvent(
            id: id, userId: "u1", taskId: taskId, kind: .increment, delta: 1,
            occurredAt: occurredAt, boardId: nil,
            createdAt: createdAt ?? occurredAt, updatedAt: createdAt ?? occurredAt,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func group(counterId: String, name: String = "Counter") -> SharedCounterGroup {
        SharedCounterGroup(
            counterId: counterId, name: name, action: "Do", unit: "reps",
            lifetime: 10, tasks: [], taskCount: 1, boardCount: 1, activeTaskCount: 1
        )
    }

    // MARK: - orderCountersByRecency / lastActivityDate

    func test_lastActivityDate_usesLatestIncrementEventCreatedAt() {
        let events: [String: [TaskEvent]] = [
            "c1": [
                event(id: "e1", taskId: "c1", occurredAt: "2026-01-01T00:00:00.000"),
                event(id: "e2", taskId: "c1", occurredAt: "2026-01-05T00:00:00.000"),
            ],
        ]
        let tasksById = ["c1": task(id: "c1", createdAt: "2025-12-01T00:00:00.000")]
        let date = ProfileHomeViewModel.lastActivityDate(counterId: "c1", tasksById: tasksById, eventsByTaskId: events)
        XCTAssertEqual(date, DateFormatting.parseISO("2026-01-05T00:00:00.000"))
    }

    func test_lastActivityDate_fallsBackToTaskCreatedAtWhenNeverLogged() {
        let tasksById = ["c1": task(id: "c1", createdAt: "2025-12-01T00:00:00.000")]
        let date = ProfileHomeViewModel.lastActivityDate(counterId: "c1", tasksById: tasksById, eventsByTaskId: [:])
        XCTAssertEqual(date, DateFormatting.parseISO("2025-12-01T00:00:00.000"))
    }

    func test_lastActivityDate_missingTaskDegradesToDistantPast() {
        let date = ProfileHomeViewModel.lastActivityDate(counterId: "ghost", tasksById: [:], eventsByTaskId: [:])
        XCTAssertEqual(date, .distantPast)
    }

    func test_orderCountersByRecency_mostRecentlyLoggedFirst() {
        let groups = [group(counterId: "old", name: "Old"), group(counterId: "new", name: "New")]
        let tasksById = [
            "old": task(id: "old", createdAt: "2026-01-01T00:00:00.000"),
            "new": task(id: "new", createdAt: "2026-01-01T00:00:00.000"),
        ]
        let events: [String: [TaskEvent]] = [
            "old": [event(id: "e1", taskId: "old", occurredAt: "2026-01-02T00:00:00.000")],
            "new": [event(id: "e2", taskId: "new", occurredAt: "2026-02-01T00:00:00.000")],
        ]
        let ordered = ProfileHomeViewModel.orderCountersByRecency(groups: groups, tasksById: tasksById, eventsByTaskId: events)
        XCTAssertEqual(ordered.map(\.counterId), ["new", "old"])
    }

    func test_orderCountersByRecency_neverLoggedFallsBackToCreatedAt() {
        let groups = [group(counterId: "a"), group(counterId: "b")]
        let tasksById = [
            "a": task(id: "a", createdAt: "2026-01-01T00:00:00.000"),
            "b": task(id: "b", createdAt: "2026-03-01T00:00:00.000"),
        ]
        // Neither has any events — pure createdAt fallback ordering.
        let ordered = ProfileHomeViewModel.orderCountersByRecency(groups: groups, tasksById: tasksById, eventsByTaskId: [:])
        XCTAssertEqual(ordered.map(\.counterId), ["b", "a"])
    }

    func test_orderCountersByRecency_mixedLoggedAndNeverLogged() {
        // "logged" was logged recently; "fresh" was only just created (never
        // logged) but more recently than "logged"'s creation — the log event
        // still wins because it's a more recent ACTIVITY instant.
        let groups = [group(counterId: "logged"), group(counterId: "fresh")]
        let tasksById = [
            "logged": task(id: "logged", createdAt: "2026-01-01T00:00:00.000"),
            "fresh": task(id: "fresh", createdAt: "2026-01-10T00:00:00.000"),
        ]
        let events: [String: [TaskEvent]] = [
            "logged": [event(id: "e1", taskId: "logged", occurredAt: "2026-02-01T00:00:00.000")],
        ]
        let ordered = ProfileHomeViewModel.orderCountersByRecency(groups: groups, tasksById: tasksById, eventsByTaskId: events)
        XCTAssertEqual(ordered.map(\.counterId), ["logged", "fresh"])
    }

    func test_orderCountersByRecency_tiesBreakByCounterIdAscending() {
        let groups = [group(counterId: "z"), group(counterId: "a")]
        let tasksById = [
            "z": task(id: "z", createdAt: "2026-01-01T00:00:00.000"),
            "a": task(id: "a", createdAt: "2026-01-01T00:00:00.000"),
        ]
        let ordered = ProfileHomeViewModel.orderCountersByRecency(groups: groups, tasksById: tasksById, eventsByTaskId: [:])
        XCTAssertEqual(ordered.map(\.counterId), ["a", "z"])
    }

    // MARK: - boardSettingsTileSummary

    func test_boardSettingsTileSummary_formatsDefaultsLine() {
        let summary = ProfileHomeViewModel.boardSettingsTileSummary(
            defaultBoardSize: .three, centerType: .free, weekStartDay: .monday, repeatingCount: 0
        )
        XCTAssertEqual(summary.defaultsLine, "Defaults 3×3 · Free · Mon")
    }

    func test_boardSettingsTileSummary_noneCenterAndSunday() {
        let summary = ProfileHomeViewModel.boardSettingsTileSummary(
            defaultBoardSize: .five, centerType: .none, weekStartDay: .sunday, repeatingCount: 0
        )
        XCTAssertEqual(summary.defaultsLine, "Defaults 5×5 · None · Sun")
    }

    func test_boardSettingsTileSummary_zeroRepeatingBoards() {
        let summary = ProfileHomeViewModel.boardSettingsTileSummary(
            defaultBoardSize: .three, centerType: .free, weekStartDay: .monday, repeatingCount: 0
        )
        XCTAssertEqual(summary.repeatingLine, "No repeating boards yet")
    }

    func test_boardSettingsTileSummary_oneRepeatingBoardIsSingular() {
        let summary = ProfileHomeViewModel.boardSettingsTileSummary(
            defaultBoardSize: .three, centerType: .free, weekStartDay: .monday, repeatingCount: 1
        )
        XCTAssertEqual(summary.repeatingLine, "1 repeating board")
    }

    func test_boardSettingsTileSummary_multipleRepeatingBoardsArePlural() {
        let summary = ProfileHomeViewModel.boardSettingsTileSummary(
            defaultBoardSize: .three, centerType: .free, weekStartDay: .monday, repeatingCount: 2
        )
        XCTAssertEqual(summary.repeatingLine, "2 repeating boards")
    }

    // MARK: - gettingStartedDisplay

    func test_gettingStartedDisplay_dayOneHeroWhenZeroCompleted() {
        XCTAssertEqual(
            ProfileHomeViewModel.gettingStartedDisplay(completedCount: 0, isComplete: false),
            .dayOneHero
        )
    }

    func test_gettingStartedDisplay_rowWhenPartiallyComplete() {
        XCTAssertEqual(
            ProfileHomeViewModel.gettingStartedDisplay(completedCount: 3, isComplete: false),
            .row
        )
    }

    func test_gettingStartedDisplay_hiddenWhenComplete() {
        XCTAssertEqual(
            ProfileHomeViewModel.gettingStartedDisplay(completedCount: 8, isComplete: true),
            .hidden
        )
    }

    // MARK: - nextIncompleteLessonTitle (Views/BoardsTab/TutorialLessons.swift)

    func test_nextIncompleteLessonTitle_firstLessonWhenNoneComplete() {
        XCTAssertEqual(nextIncompleteLessonTitle(completedIDs: []), tutorialLessons[0].title)
    }

    func test_nextIncompleteLessonTitle_skipsCompletedLessonsInOrder() {
        let completed = Set([tutorialLessons[0].id, tutorialLessons[1].id])
        XCTAssertEqual(nextIncompleteLessonTitle(completedIDs: completed), tutorialLessons[2].title)
    }

    func test_nextIncompleteLessonTitle_nilWhenAllComplete() {
        let completed = Set(tutorialLessons.map(\.id))
        XCTAssertNil(nextIncompleteLessonTitle(completedIDs: completed))
    }

    // MARK: - load() integration (AppDatabase.makeTestInstance())

    private func seedUser(_ db: AppDatabase, id: String = "u1") throws {
        let now = AppDatabase.currentTimestamp()
        let user = User(
            id: id, email: "test@example.com", displayName: "Test User", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
        try db.saveUser(user)
    }

    private func makeTemplate(id: String, userId: String = "u1", isActive: Bool = true) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id, userId: userId, name: "Template \(id)",
            timeframe: .weekly, boardSize: 3, centerSquareType: .free,
            isRandomized: false, seedTaskIds: [],
            isActive: isActive,
            createdAt: "2026-01-01T00:00:00.000", updatedAt: "2026-01-01T00:00:00.000"
        )
    }

    func test_load_populatesRepeatingBoardsCountAndCounters() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveRecurringBoardTemplate(makeTemplate(id: "t1"))
        try db.saveRecurringBoardTemplate(makeTemplate(id: "t2", isActive: false))

        // A source counting task + a linked member — makes one counter group.
        try db.write { txn in
            try task(id: "src", currentCount: 42, isCounter: true).save(txn)
            try task(id: "linked", sharedCounterId: "src").save(txn)
        }

        let vm = ProfileHomeViewModel(db: db)
        XCTAssertFalse(vm.isLoaded)
        vm.load(userId: "u1", weekStartDay: "monday")

        let loaded = try waitUntil(timeout: 2) { vm.isLoaded }
        XCTAssertTrue(loaded, "vm.isLoaded never became true")

        XCTAssertEqual(vm.repeatingBoardsCount, 2, "counts ALL non-deleted templates, active and paused")
        XCTAssertEqual(vm.totalCounterCount, 1)
        XCTAssertEqual(vm.recentCounters.map(\.counterId), ["src"])
        XCTAssertEqual(vm.recentCounters.first?.lifetime, 42)
        XCTAssertEqual(vm.streak.greenlogCount, 0)
    }

    // MARK: - "+ Log" / Undo (toast parity with the Counters Hub)

    /// Seeds one hub-born counter and loads the VM — the fixture both
    /// "+ Log" tests start from.
    private func makeLoadedCounterVM() throws -> (ProfileHomeViewModel, AppDatabase) {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.write { txn in
            try task(id: "src", currentCount: 5, isCounter: true).save(txn)
        }
        let vm = ProfileHomeViewModel(db: db)
        vm.load(userId: "u1", weekStartDay: "monday")
        XCTAssertTrue(try waitUntil(timeout: 2) { vm.isLoaded })
        return (vm, db)
    }

    func test_handleLog_incrementsSourceAndRaisesUndoableToast() throws {
        let (vm, db) = try makeLoadedCounterVM()
        let group = try XCTUnwrap(vm.recentCounters.first)
        XCTAssertNil(vm.toast)

        var errors: [String] = []
        vm.handleLog(group: group, userId: "u1", weekStartDay: "monday") { errors.append($0) }
        XCTAssertTrue(try waitUntil(timeout: 2) { vm.toast != nil })

        XCTAssertEqual(errors, [])
        XCTAssertEqual(vm.toast?.counterId, "src")
        XCTAssertEqual(vm.toast?.amount, 1, "logs `defaultLogAmount ?? 1`")
        XCTAssertEqual(vm.toast?.unit, "reps")
        XCTAssertEqual(vm.toast?.verb, .logged)
        // The write went through the shared-counter op: source row bumped…
        XCTAssertEqual(try db.fetchTask(id: "src")?.currentCount, 6)
        // …and the reload reflects it.
        XCTAssertTrue(try waitUntil(timeout: 2) { vm.recentCounters.first?.lifetime == 6 })
    }

    func test_handleUndo_reversesLastLogAndClearsToast() throws {
        let (vm, db) = try makeLoadedCounterVM()
        let group = try XCTUnwrap(vm.recentCounters.first)
        vm.handleLog(group: group, userId: "u1", weekStartDay: "monday") { _ in }
        XCTAssertTrue(try waitUntil(timeout: 2) { vm.toast != nil })
        XCTAssertEqual(try db.fetchTask(id: "src")?.currentCount, 6)

        var errors: [String] = []
        vm.handleUndo(counterId: "src", userId: "u1", weekStartDay: "monday") { errors.append($0) }
        XCTAssertTrue(try waitUntil(timeout: 2) { vm.toast == nil })

        XCTAssertEqual(errors, [])
        XCTAssertEqual(try db.fetchTask(id: "src")?.currentCount, 5, "undo tombstones the log and restores the count")
        XCTAssertTrue(try waitUntil(timeout: 2) { vm.recentCounters.first?.lifetime == 5 })
    }

    /// Polls `condition()` on the main run loop until it's true or `timeout`
    /// elapses — same convention as `BoardPlayViewModelTests` for asserting
    /// against a `_Concurrency.Task.detached` background load without
    /// controlling async ordering directly.
    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
