import XCTest
import GRDB
@testable import OYBC

@MainActor
final class CreateFormViewModelCountKindTests: XCTestCase {
    private typealias K = LinkedWindowKit

    private func form(_ db: AppDatabase, kind: CountKind, goal: String, unit: String, action: String = "Run") -> CreateFormViewModel {
        let f = CreateFormViewModel(database: db)
        f.taskType = .counting
        f.countingAction = action
        f.countingUnit = unit
        f.countingMaxCount = goal
        f.countingKind = kind
        return f
    }

    private func create(_ f: CreateFormViewModel) -> String? {
        let done = expectation(description: "created")
        var id: String?
        f.handleCreateAndAddToPool(userId: K.userId, onTaskCreated: { tid, _, _ in id = tid; done.fulfill() }, onLibraryReloadRequested: {})
        wait(for: [done], timeout: 5)
        return id
    }

    func testDurationCreateHasNoUnitAndStoresMinutes() throws {
        let db = try AppDatabase.makeTestInstance(); try K.seedUser(db)
        let id = try XCTUnwrap(create(form(db, kind: .duration, goal: "10h 30m", unit: "", action: "Practice")))
        let task = try XCTUnwrap(db.fetchTask(id: id))
        XCTAssertEqual(task.countKind, .duration)
        XCTAssertEqual(task.maxCount, 630)
        XCTAssertEqual(task.unit, "")
        XCTAssertEqual(task.title, "Practice 10h 30m")
    }

    func testContinuousRejectsThreePlaces() throws {
        let db = try AppDatabase.makeTestInstance(); try K.seedUser(db)
        let f = form(db, kind: .continuous, goal: "3.125", unit: "mi")
        f.handleCreateAndAddToPool(userId: K.userId, onTaskCreated: { _, _, _ in XCTFail("must not create") }, onLibraryReloadRequested: {})
        XCTAssertEqual(f.errorMessage, "Goal must be a number above zero with up to 2 decimals")
    }

    /// Review Focus 3 — the picker said Discrete, the create auto-links to a
    /// Continuous root: the 6.2 goal must PARSE at the root kind and the row
    /// must SAVE as Continuous.
    func testLinkedCreateSavesRootKindAndParsesAtIt() throws {
        let db = try AppDatabase.makeTestInstance(); try K.seedUser(db)
        var root = K.task("root", maxCount: 26.2, currentCount: 148.6); root.countKind = .continuous
        try db.saveTask(root)
        let f = form(db, kind: .discrete, goal: "6.2", unit: "miles")
        f.countingSharedCounterId = "root"
        f.countingBaseline = 148.6
        f.countingLinkedRootKind = .continuous
        let id = try XCTUnwrap(create(f))
        let row = try XCTUnwrap(db.fetchTask(id: id))
        XCTAssertEqual(row.countKind, .continuous)
        XCTAssertEqual(row.maxCount, 6.2)
        XCTAssertEqual(row.title, "Run 6.2 miles")
    }

    /// R19 — a deferred (wizard) create carries the root kind on the pending
    /// payload itself, before the drain's `withRootCountKind`.
    func testDeferredLinkedCreateCarriesRootKindOnThePayload() throws {
        let db = try AppDatabase.makeTestInstance(); try K.seedUser(db)
        let f = form(db, kind: .discrete, goal: "6.2", unit: "miles")
        f.countingSharedCounterId = "root"; f.countingBaseline = 0; f.countingLinkedRootKind = .continuous
        let done = expectation(description: "pending")
        var payload: PendingTaskPayload?
        f.handleCreateAndAddToPool(userId: K.userId, onTaskCreated: { _, _, _ in }, onLibraryReloadRequested: {},
                                   deferPersist: true, onPendingCreated: { payload = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(payload?.task.countKind, .continuous)
    }
}
