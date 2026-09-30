import XCTest
import GRDB
@testable import OYBC

/// Regression: "a counter derived from a monthly counting task onto a weekly
/// board via the Sources sheet vanishes from the Counters hub (and the
/// Profile home's Shared counters block) once the weekly window ends".
///
/// A board-born counter is a root only because a live task links to it. The
/// hub's expired-member filter used to run BEFORE `buildSharedCounterGroups`
/// (`filterCounterTasks`), so when its only members expired the root stopped
/// being a root and the whole group disappeared — "Show expired" brought it
/// back. The rule now lives in the kernel (`memberVisibility`) and runs
/// AFTER root detection.
///
/// Drives the REAL wizard persist path (`BoardWizardViewModel` →
/// `buildWizardPlacement` → `resolveWizardDates` → `persistWizardBoard` →
/// `mintWizardDerivedRows`) against a test DB, then reads the hub through
/// `fetchSharedCounterGroups(userId:showExpired:now:)` — exactly what
/// `CountersHubView` / `CounterDetailView` / `ProfileHomeViewModel` call.
/// The wizard's window boundaries read the real wall clock; the hub reads
/// are pinned by an injected `now`.
final class SharedCounterHubExpiryRegressionTests: XCTestCase {

    private let userId = "u-hub-expiry"
    private let rootId = "run-miles"

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "r@e.com", displayName: "R", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        var root = OYBC.Task(
            id: rootId, userId: userId, title: "Run 100 miles", type: .counting,
            action: "Run", unit: "miles", maxCount: 100,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, currentCount: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        root.createdInWizard = true   // quick-added inside the monthly wizard
        try db.saveTask(root)
        for i in 0..<8 {
            try db.saveTask(OYBC.Task(
                id: "n\(i)", userId: userId, title: "Normal \(i)", type: .normal,
                totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            ))
        }
        return db
    }

    private func library(_ db: AppDatabase) throws -> TaskLibraryViewModel {
        let lib = TaskLibraryViewModel(database: db)
        lib.libraryTasks = try db.fetchTasks(userId: userId)
        return lib
    }

    @discardableResult
    private func persist(_ vm: BoardWizardViewModel, _ db: AppDatabase, status: WizardStatus) throws -> String {
        guard case .ok(let start, let end) = resolveWizardDates(controller: vm) else {
            XCTFail("dates did not resolve"); return ""
        }
        let placement = buildWizardPlacement(controller: vm, library: try library(db))
        let exp = XCTestExpectation(description: "persist")
        var result: String?
        var err: String?
        persistWizardBoard(
            controller: vm, userId: userId, placement: placement,
            dates: (start, end), status: status, database: db,
            onSuccess: { result = $0; exp.fulfill() },
            onError: { err = $0; exp.fulfill() }
        )
        wait(for: [exp], timeout: 10)
        XCTAssertNil(err, "persist error: \(err ?? "")")
        return try XCTUnwrap(result)
    }

    /// A monthly one-off board carrying the Run/miles/100 counter + 8 fillers.
    private func makeMonthly(_ db: AppDatabase) throws -> String {
        let vm = BoardWizardViewModel(preferences: .defaults, userId: userId, database: db)
        vm.name = "September"
        vm.updateTimeframe(.monthly)
        vm.updateSize(3)
        vm.updateCenterType(.none)
        vm.isRandomized = false
        for id in [rootId] + (0..<8).map({ "n\($0)" }) { vm.toggleTaskSelection(id) }
        return try persist(vm, db, status: .active)
    }

    /// A weekly board that pulls the monthly via the Sources sheet, with an
    /// explicit target on the counter member.
    private func configureWeekly(_ vm: BoardWizardViewModel, monthlyId: String, target: Int) {
        vm.name = "This week"
        if !vm.isCore { vm.updateTimeframe(.weekly) }
        vm.updateSize(3)
        vm.updateCenterType(.none)
        vm.isRandomized = false
        vm.pullBoard(boardId: monthlyId)
        vm.setMemberTarget(sourceId: monthlyId, taskId: rootId, target: target)
    }

    /// A core weekly board (the pager's Set-up / banner path) for the window
    /// holding `windowDate`.
    @MainActor
    private func makeCoreWeekly(_ db: AppDatabase, monthlyId: String, windowDate: Date) throws -> String {
        let vm = BoardWizardViewModel(
            preferences: .defaults, prefilledRecurringTimeframe: .weekly,
            targetWindowDate: windowDate, userId: userId, database: db
        )
        XCTAssertTrue(vm.isCore)
        configureWeekly(vm, monthlyId: monthlyId, target: 25)
        return try persist(vm, db, status: .active)
    }

    private func derivedRow(_ db: AppDatabase) throws -> OYBC.Task {
        try XCTUnwrap(try db.read { db in
            try OYBC.Task
                .filter(Column("sharedCounterId") == self.rootId && Column("isDeleted") == false)
                .fetchOne(db)
        }, "one window-stamped derived row was minted for the weekly")
    }

    private func hubGroup(
        _ db: AppDatabase, showExpired: Bool, now: Date
    ) -> SharedCounterGroup? {
        db.fetchSharedCounterGroups(userId: userId, showExpired: showExpired, now: now)
            .groups.first { $0.counterId == rootId }
    }

    // MARK: - Baseline: a live weekly member lists under the monthly root

    @MainActor func test_liveWeeklyMember_listsUnderTheMonthlyRoot() throws {
        let db = try makeDb()
        let monthlyId = try makeMonthly(db)
        let vm = BoardWizardViewModel(preferences: .defaults, userId: userId, database: db)
        configureWeekly(vm, monthlyId: monthlyId, target: 25)
        XCTAssertTrue(vm.selectedTaskIds.contains(rootId), "source supplied the root; sources=\(vm.sources)")
        let weeklyId = try persist(vm, db, status: .active)

        let d = try derivedRow(db)
        XCTAssertTrue(BoardSources.isWindowStampedDerived(d))
        XCTAssertEqual(d.maxCount, 25)
        let placed = try db.read { db in
            try BoardTask.filter(Column("boardId") == weeklyId && Column("isDeleted") == false).fetchAll(db)
        }.map(\.taskId)
        XCTAssertTrue(placed.contains(d.id), "the weekly places the derived row")

        let group = try XCTUnwrap(hubGroup(db, showExpired: false, now: Date()))
        XCTAssertEqual(group.tasks.map(\.taskId), [rootId, d.id])
    }

    // MARK: - The bug: the root vanished once its only member expired

    /// (d) Core weekly for THIS week; the hub is read after the week ends.
    /// Red before the fix: the group was gone. Now: the root stays, listed
    /// with its lifetime total and no members counting; "Show expired"
    /// lists the ended weekly row again.
    @MainActor func test_coreWeekly_rootStaysInTheHubAfterTheWeekEnds() throws {
        let db = try makeDb()
        let monthlyId = try makeMonthly(db)
        try makeCoreWeekly(db, monthlyId: monthlyId, windowDate: Date())
        let d = try derivedRow(db)
        let end = try XCTUnwrap(TaskExpiry.parseTaskEndDate(try XCTUnwrap(d.endDate)))
        let later = end.addingTimeInterval(3600)
        XCTAssertTrue(TaskExpiry.isTaskExpired(d, now: later), "the weekly member is over at `later`")

        let hidden = try XCTUnwrap(
            hubGroup(db, showExpired: false, now: later),
            "after the weekly window ends, the MONTHLY root must stay in the hub"
        )
        XCTAssertEqual(hidden.tasks.map(\.taskId), [rootId], "only the source row; the ended member is hidden")
        XCTAssertEqual(hidden.taskCount, 1)
        XCTAssertEqual(hidden.lifetime, 0)

        let shown = try XCTUnwrap(hubGroup(db, showExpired: true, now: later))
        XCTAssertEqual(shown.tasks.map(\.taskId), [rootId, d.id], "Show expired lists the ended weekly row")
    }

    /// (e) Core weekly set up for LAST week's window (pager swiped back), hub
    /// read now — the member is already expired when it is minted.
    @MainActor func test_corePastWeek_rootIsInTheHubNow() throws {
        let db = try makeDb()
        let monthlyId = try makeMonthly(db)
        try makeCoreWeekly(db, monthlyId: monthlyId, windowDate: Date().addingTimeInterval(-7 * 86400))
        let d = try derivedRow(db)
        let now = Date()
        XCTAssertTrue(TaskExpiry.isTaskExpired(d, now: now), "last week's member is over already")

        let hidden = try XCTUnwrap(
            hubGroup(db, showExpired: false, now: now),
            "the MONTHLY root must be in the hub even though its only member is last week's"
        )
        XCTAssertEqual(hidden.tasks.map(\.taskId), [rootId])

        let shown = try XCTUnwrap(hubGroup(db, showExpired: true, now: now))
        XCTAssertEqual(shown.tasks.map(\.taskId), [rootId, d.id])
    }

    /// The Profile home's Shared counters block reads the same kernel — it
    /// must keep counting the root after the weekly ends.
    @MainActor func test_profileHome_keepsTheCounterAfterTheWeekEnds() throws {
        let db = try makeDb()
        let monthlyId = try makeMonthly(db)
        try makeCoreWeekly(db, monthlyId: monthlyId, windowDate: Date())
        let d = try derivedRow(db)
        let end = try XCTUnwrap(TaskExpiry.parseTaskEndDate(try XCTUnwrap(d.endDate)))
        let later = end.addingTimeInterval(3600)

        let vm = ProfileHomeViewModel(db: db)
        vm.load(userId: userId, weekStartDay: "monday", now: later)
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in vm.isLoaded }, object: nil
        )
        wait(for: [loaded], timeout: 5)

        XCTAssertEqual(vm.totalCounterCount, 1, "the counter still counts on the Profile home")
        XCTAssertEqual(vm.recentCounters.map(\.counterId), [rootId])
    }
}
