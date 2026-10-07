import XCTest
import GRDB
@testable import OYBC

/// Board Edit kind switch through the REAL path: `handleEditTaskOverride` →
/// `handleEditSave` → outcome. Fixtures copied from `BoardEditCompoundTests`.
@MainActor
final class BoardEditKindSwitchTests: XCTestCase {

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(id: "u1", email: "t@example.com", displayName: "T", photoURL: nil,
                             preferences: User.encodePreferences(.defaults), createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1))
        let dict: [String: Any] = [
            "id": "b1", "userId": "u1", "name": "Board b1", "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue, "startDate": "2026-06-21T00:00:00.000", "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue, "isRandomized": false, "totalTasks": 9, "completedTasks": 0,
            "linesCompleted": 0, "createdAt": "2026-06-21T00:00:00.000", "updatedAt": "2026-06-21T00:00:00.000", "version": 1, "isDeleted": false,
        ]
        try db.saveBoard(try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict)))
        return db
    }

    private func counting(_ id: String, kind: CountKind, maxCount: CountValue, sharedCounterId: String? = nil) -> Task {
        var t = LinkedWindowKit.task(id, maxCount: maxCount, sharedCounterId: sharedCounterId, baseline: sharedCounterId == nil ? nil : 0, title: "Run \(id)")
        t.countKind = kind
        return t
    }

    private func place(_ db: AppDatabase, _ taskId: String, col: Int) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveBoardTask(BoardTask(id: "bt-\(taskId)", boardId: "b1", taskId: taskId, row: 0, col: col, isCenter: false,
                                       createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1))
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }

    private func loadedVM(_ db: AppDatabase) -> BoardPlayViewModel {
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()
        _ = waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty }
        vm.seedEditDraft(from: vm.board!)
        return vm
    }

    private func save(_ vm: BoardPlayViewModel) -> BoardPlayEditEvent.Outcome? {
        XCTAssertTrue(vm.handleEditSave(), "save should dispatch")
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome != nil }, "no outcome emitted")
        return vm.editEvent?.outcome
    }

    private func patch(goal: CountValue?, kind: CountKind?, title: String = "Run 30 miles") -> SquareEditTaskSheet.Patch {
        .init(title: title, type: .counting, action: "Run", unit: "miles", maxCount: goal, compound: nil, countKind: kind)
    }

    /// Review Focus 4 — a staged Continuous → Discrete switch plus a goal edit commit together.
    func testSwitchThenGoalEditAtomic() throws {
        let db = try makeDb()
        try db.saveTask(counting("root", kind: .continuous, maxCount: 26.2))
        try place(db, "root", col: 0)
        let vm = loadedVM(db)
        vm.handleEditTaskOverride(taskId: "root", patch: patch(goal: 30, kind: .discrete))
        let staged = try XCTUnwrap(vm.editDraftTaskMap["root"])
        XCTAssertEqual(resolveCountKind(staged.countKind), .discrete, "the staged grid (and a reopened sheet) shows the staged kind")
        XCTAssertEqual(try db.fetchTask(id: "root")?.countKind, .continuous, "nothing is written before Save")
        XCTAssertEqual(save(vm), .saved)
        let row = try XCTUnwrap(db.fetchTask(id: "root"))
        XCTAssertEqual(row.countKind, .discrete)
        XCTAssertEqual(row.maxCount, 30)
        XCTAssertEqual(row.title, "Run 30 miles")
    }

    func testFractionalGoalAtTheNewWholeKindRollsTheSaveBack() throws {
        let db = try makeDb()
        try db.saveTask(counting("root", kind: .continuous, maxCount: 26.2))
        try place(db, "root", col: 0)
        let vm = loadedVM(db)
        vm.handleEditTaskOverride(taskId: "root", patch: patch(goal: 26.5, kind: .discrete, title: "x"))
        guard case .saveFailed = try XCTUnwrap(save(vm)) else { return XCTFail("expected saveFailed") }
        let row = try XCTUnwrap(db.fetchTask(id: "root"))
        XCTAssertEqual(row.countKind, .continuous)
        XCTAssertEqual(row.maxCount, 26.2)
        XCTAssertEqual(row.version, 1)
    }

    func testAPlacedLinkedCopyIsNeverSwitched() throws {
        let db = try makeDb()
        try db.saveTask(counting("root", kind: .continuous, maxCount: 26.2))
        try db.saveTask(counting("copy", kind: .continuous, maxCount: 6.2, sharedCounterId: "root"))
        try place(db, "copy", col: 0)
        let vm = loadedVM(db)
        vm.handleEditTaskOverride(taskId: "copy", patch: patch(goal: nil, kind: .discrete, title: "Run copy"))
        XCTAssertEqual(save(vm), .saved)
        XCTAssertEqual(try db.fetchTask(id: "copy")?.countKind, .continuous)
        XCTAssertEqual(try db.fetchTask(id: "root")?.countKind, .continuous)
    }

    /// A Simple square converted to Counting takes the chosen kind directly
    /// (Duration: no unit, title in hours + minutes).
    func testSimpleConvertedToDurationCountingSavesTheKind() throws {
        let db = try makeDb()
        var simple = LinkedWindowKit.task("s", maxCount: nil, title: "Practice")
        simple.type = .normal
        simple.action = nil
        simple.unit = nil
        try db.saveTask(simple)
        try place(db, "s", col: 0)
        let vm = loadedVM(db)
        vm.handleEditTaskOverride(taskId: "s", patch: .init(
            title: "", type: .counting, action: "Practice", unit: "", maxCount: 90, compound: nil, countKind: .duration
        ))
        XCTAssertEqual(save(vm), .saved)
        let row = try XCTUnwrap(db.fetchTask(id: "s"))
        XCTAssertEqual(row.type, .counting)
        XCTAssertEqual(row.countKind, .duration)
        XCTAssertEqual(row.maxCount, 90)
        XCTAssertEqual(row.title, "Practice 1h 30m")
    }

    /// A Counting square switched to Simple drops its kind with its other counting fields.
    func testCountingSwitchedToSimpleDropsTheKind() throws {
        let db = try makeDb()
        try db.saveTask(counting("root", kind: .continuous, maxCount: 26.2))
        try place(db, "root", col: 0)
        let vm = loadedVM(db)
        vm.handleEditTaskOverride(taskId: "root", patch: .init(
            title: "Run", type: .normal, action: "", unit: "", maxCount: nil, compound: nil, countKind: nil
        ))
        XCTAssertEqual(save(vm), .saved)
        let row = try XCTUnwrap(db.fetchTask(id: "root"))
        XCTAssertEqual(row.type, .normal)
        XCTAssertNil(row.countKind)
    }
}
