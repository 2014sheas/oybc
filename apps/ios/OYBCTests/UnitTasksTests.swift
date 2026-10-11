import XCTest
import GRDB
@testable import OYBC

/// Unit tasks (iOS half, docs/SHARED_COUNTER_SETTINGS.md §3d): the shared
/// strings, the remove gate, the progress label, the counter name the "+ New"
/// sheet's tag reads, the arrival diff and the counter-delete impact count.
/// Web twin: `countsTowardLabels.test.ts`. The ordering / progress derivations
/// are vector-pinned in `CountsTowardVectorTests`.
@MainActor
final class UnitTasksTests: XCTestCase {

    private let user = "user-1"
    private let t0 = "2026-01-01T00:00:00.000Z"
    private let root = "00000000-0000-4000-8000-0000000000a1"

    // MARK: - Labels

    func test_heading() {
        XCTAssertEqual(CountsTowardLabels.heading(count: 0), "Unit tasks")
        XCTAssertEqual(CountsTowardLabels.heading(count: 1), "Unit tasks \u{00B7} 1")
        XCTAssertEqual(CountsTowardLabels.heading(count: 6), "Unit tasks \u{00B7} 6")
        XCTAssertEqual(CountsTowardLabels.empty, "No unit tasks yet.")
    }

    func test_progressLabelUsesTheTasksRealKind() {
        let discrete = CountsToward.Progress(current: 120, goal: 300, kind: .discrete)
        XCTAssertEqual(CountsTowardLabels.progress(discrete, unit: "pages"), "120 / 300 pages")
        let miles = CountsToward.Progress(current: 3.5, goal: 10, kind: .continuous)
        XCTAssertEqual(CountsTowardLabels.progress(miles, unit: "mi"), "3.5 / 10 mi")
        let time = CountsToward.Progress(current: 90, goal: 300, kind: .duration)
        XCTAssertEqual(CountsTowardLabels.progress(time, unit: "ignored"), "1h 30m / 5h")
    }

    func test_childProgressLabel() {
        XCTAssertEqual(CountsTowardLabels.childProgress(.init(done: 0, total: 0)), "No subtasks yet")
        XCTAssertEqual(CountsTowardLabels.childProgress(.init(done: 1, total: 2)), "1 of 2")
    }

    func test_removeConfirmCopyAndGate() {
        XCTAssertEqual(CountsTowardLabels.removeTitle(counter: "Books"), "Remove from Books?")
        XCTAssertEqual(
            CountsTowardLabels.removeBody(title: "Read before bed", credits: 4, counter: "Books"),
            "'Read before bed' stays in your library. Its 4 credits on Books are withdrawn."
        )
        XCTAssertEqual(
            CountsTowardLabels.removeBody(title: "Dune", credits: 1, counter: "Books"),
            "'Dune' stays in your library. Its 1 credit on Books is withdrawn."
        )
        XCTAssertFalse(CountsTowardLabels.removeNeedsConfirm(creditCount: 0))
        XCTAssertTrue(CountsTowardLabels.removeNeedsConfirm(creditCount: 1))
    }

    func test_deleteNotePluralisationAndHiddenAtZero() {
        XCTAssertNil(CountsTowardLabels.deleteNote(unitTaskCount: 0))
        XCTAssertEqual(CountsTowardLabels.deleteNote(unitTaskCount: 1), "Its 1 unit task is kept as an ordinary task.")
        XCTAssertEqual(CountsTowardLabels.deleteNote(unitTaskCount: 6), "Its 6 unit tasks are kept as ordinary tasks.")
    }

    func test_tagAndSubmitLabels() {
        XCTAssertEqual(CountsTowardLabels.tagAccessibility(counter: "Books"), "Unit task of Books")
        XCTAssertEqual(CountsTowardLabels.submitLabel, "Add to library")
    }

    func test_boardLineDetailGating() {
        func r(_ st: CountsToward.ContributorRowStatus, p: CountsToward.Progress? = nil, c: CountsToward.ChildProgress? = nil) -> CountsToward.ContributorRow {
            .init(taskId: "t", status: st, boardId: nil, creditCount: 0, latestOccurredAt: nil, progress: p, childProgress: c)
        }
        let p = CountsToward.Progress(current: 0, goal: 300, kind: .discrete)
        XCTAssertNil(CountsTowardSectionView.detailText(row: r(.notStarted, p: p), unit: "pages"))
        XCTAssertEqual(CountsTowardSectionView.detailText(row: r(.inProgress, p: .init(current: 120, goal: 300, kind: .discrete)), unit: "pages"), "120 / 300 pages")
        XCTAssertEqual(CountsTowardSectionView.detailText(row: r(.notStarted, c: .init(done: 0, total: 0)), unit: nil), "No subtasks yet")
        XCTAssertEqual(CountsTowardSectionView.detailText(row: r(.done, c: .init(done: 0, total: 0)), unit: nil), "No subtasks yet")
        XCTAssertEqual(CountsTowardSectionView.detailText(row: r(.inProgress, c: .init(done: 1, total: 2)), unit: nil), "1 of 2")
        XCTAssertNil(CountsTowardSectionView.detailText(row: r(.done, c: .init(done: 2, total: 2)), unit: nil))
        XCTAssertNil(CountsTowardSectionView.detailText(row: r(.notStarted, c: .init(done: 0, total: 2)), unit: nil))
    }

    // MARK: - Arrival diff

    private func data(_ ids: [String]) -> CountsTowardSectionData {
        CountsTowardSectionData(
            counterName: "Books",
            rows: ids.map { .init(taskId: $0, status: .notStarted, boardId: nil, creditCount: 0, latestOccurredAt: nil) },
            taskById: [:], boardById: [:]
        )
    }

    func test_arrivedRowIsTheOneNotThereBefore() {
        XCTAssertEqual(CounterDetailView.arrivedRowId(old: data(["a", "b"]), new: data(["a", "n", "b"])), "n")
        XCTAssertNil(CounterDetailView.arrivedRowId(old: data(["a"]), new: data(["a"])))
        XCTAssertEqual(CounterDetailView.arrivedRowId(old: nil, new: data(["a"])), "a")
        XCTAssertNil(CounterDetailView.arrivedRowId(old: data(["a"]), new: nil))
    }

    // MARK: - DB-backed

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try db.saveUser(User(
            id: user, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults), createdAt: t0, updatedAt: t0, lastSyncedAt: nil, version: 1
        ))
        return db
    }

    private func task(_ id: String, type: TaskType = .normal, isCounter: Bool = false, countsToward: String? = nil) -> Task {
        Task(
            id: id, userId: user, title: id, type: type,
            action: type == .counting ? "Read" : nil, unit: type == .counting ? "books" : nil,
            maxCount: type == .counting ? 12 : nil, totalCompletions: 0, totalInstances: 0,
            currentCount: type == .counting ? 0 : nil, createdAt: t0, updatedAt: t0, version: 1, isDeleted: false,
            isCounter: isCounter, countsTowardCounterId: countsToward, countsTowardSince: countsToward == nil ? nil : t0
        )
    }

    func test_presetCounterNameReadsTheRoot() throws {
        let db = try makeDb()
        let counter = task(root, type: .counting, isCounter: true)
        try db.saveTask(counter)
        XCTAssertEqual(
            NewTaskSheetView.presetCounterName(database: db, counterId: root),
            CounterSettings.counterDisplayName(counter)
        )
        XCTAssertNil(NewTaskSheetView.presetCounterName(database: db, counterId: nil))
        XCTAssertNil(NewTaskSheetView.presetCounterName(database: db, counterId: "missing"))
    }

    func test_deletionImpactCountsLiveUnitTasks() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, isCounter: true))
        try db.saveTask(task("u1", countsToward: root))
        try db.saveTask(task("u2", type: .compound, countsToward: root))
        try db.saveTask(task("other"))
        XCTAssertEqual(try db.computeTaskDeletionImpact(taskId: root).unitTaskCount, 2)
        XCTAssertEqual(try db.computeTaskDeletionImpact(taskId: "other").unitTaskCount, 0)
    }

    func test_removeClearsTheCounter() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, isCounter: true))
        try db.saveTask(task("u1", countsToward: root))
        try db.setCountsToward(taskId: "u1", counterId: nil)
        XCTAssertNil(try db.fetchTask(id: "u1")?.countsTowardCounterId)
        XCTAssertEqual(try db.fetchCountsTowardSection(counterId: root)?.rows.count, 0)
    }
}
