import XCTest
import GRDB
@testable import OYBC

/// Board-scoped task edits PR 1 (docs/BOARD_SCOPED_TASK_EDITS.md) — the
/// inert foundation on iOS:
///   - `Task.forkedFromTaskId` persists through GRDB v41, decodes
///     forward-compatibly, and is nil-skipped on encode;
///   - a fork is never browsable, never a compound sub-task candidate, never
///     source supply (twins of `boardScopedForkGuards.test.ts`);
///   - `deleteTaskWithCascade` leaves a fork, its placement and its events
///     untouched (twin of web `taskDeletionForks.test.ts`).
final class BoardScopedForkFoundationTests: XCTestCase {

    private static let t0 = "2026-10-05T00:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try db.saveUser(User(
            id: "u1", email: "test@example.com", displayName: "Test User", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: Self.t0, updatedAt: Self.t0, lastSyncedAt: nil, version: 1
        ))
        return db
    }

    private func task(
        _ id: String,
        title: String? = nil,
        type: TaskType = .normal,
        createdInWizard: Bool = false,
        forkedFromTaskId: String? = nil
    ) -> Task {
        Task(
            id: id, userId: "u1", title: title ?? "Task \(id)", type: type,
            maxCount: type == .counting ? 10 : nil,
            totalCompletions: 0, totalInstances: 1,
            createdAt: Self.t0, updatedAt: Self.t0, version: 1, isDeleted: false,
            createdInWizard: createdInWizard,
            forkedFromTaskId: forkedFromTaskId
        )
    }

    private func board(_ id: String) throws -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": "u1", "name": id, "status": "active", "boardSize": 3,
            "timeframe": "weekly", "startDate": Self.t0, "endDate": "2026-10-11T23:59:59.999Z",
            "centerSquareType": "none", "isRandomized": false, "totalTasks": 9,
            "completedTasks": 0, "linesCompleted": 0, "createdAt": Self.t0,
            "updatedAt": Self.t0, "version": 1, "isDeleted": false,
        ]
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func placement(_ id: String, board: String, task: String) -> BoardTask {
        BoardTask(
            id: id, boardId: board, taskId: task, row: 0, col: 0, isCenter: false,
            createdAt: Self.t0, updatedAt: Self.t0, version: 1, isDeleted: false
        )
    }

    private func completion(_ id: String, task: String) -> TaskEvent {
        TaskEvent(
            id: id, userId: "u1", taskId: task, kind: .completion, delta: nil,
            occurredAt: "2026-10-06T09:00:00.000Z", boardId: nil,
            createdAt: Self.t0, updatedAt: Self.t0, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
    }

    // MARK: - Model / migration

    func testForkedFromTaskIdRoundTripsThroughGRDB() throws {
        let db = try makeDb()
        try db.write { try self.task("orig").save($0) }
        try db.write { try self.task("fork", forkedFromTaskId: "orig").save($0) }
        let back = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "fork") })
        XCTAssertEqual(back.forkedFromTaskId, "orig")
        let plain = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "orig") })
        XCTAssertNil(plain.forkedFromTaskId)
    }

    func testV41AddsNullableColumn() throws {
        let db = try makeDb()
        let columns = try db.read { try $0.columns(in: "tasks") }
        let column = try XCTUnwrap(columns.first { $0.name == "forkedFromTaskId" })
        XCTAssertEqual(column.type.uppercased(), "TEXT")
        XCTAssertFalse(column.isNotNull)
    }

    func testPreFeaturePayloadDecodesAsNilAndEncodeSkipsNil() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task("t"))) as! [String: Any]
        XCTAssertNil(json["forkedFromTaskId"], "nil must be skipped on encode (no explicit null on the wire)")
        json.removeValue(forKey: "forkedFromTaskId")
        let decoded = try JSONDecoder().decode(Task.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.forkedFromTaskId)

        json["forkedFromTaskId"] = "orig"
        let fork = try JSONDecoder().decode(Task.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(fork.forkedFromTaskId, "orig")
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fork)) as! [String: Any]
        XCTAssertEqual(reencoded["forkedFromTaskId"] as? String, "orig")
    }

    // MARK: - Guards

    func testForkIsNeverBrowsable() {
        let out = BrowsableTasks.computeBrowsableTasks(
            tasks: [
                task("orig"),
                task("wiz", createdInWizard: true),
                task("fork", createdInWizard: true, forkedFromTaskId: "orig"),
                task("stripped", forkedFromTaskId: "orig"),
            ],
            boardTasks: [
                placement("p1", board: "active", task: "orig"),
                placement("p2", board: "active", task: "wiz"),
                placement("p3", board: "active", task: "fork"),
                placement("p4", board: "active", task: "stripped"),
            ],
            boardStatusById: ["active": .active]
        )
        XCTAssertEqual(out.map(\.id), ["orig", "wiz"])
    }

    func testForkIsNeverASubTaskCandidate() {
        let out = CompoundChildEligibility.pickerCandidates(
            parentId: "parent",
            browsable: [task("a", title: "Alpha"), task("f", title: "Beta", forkedFromTaskId: "a")],
            allLinks: [],
            currentChildIds: []
        )
        XCTAssertEqual(out.map(\.id), ["a"])
    }

    func testForkIsNeverSourceSupply() {
        XCTAssertTrue(BoardSources.isSourceSupplyTask(task("orig")))
        XCTAssertFalse(BoardSources.isSourceSupplyTask(task("fork", forkedFromTaskId: "orig")))
        XCTAssertFalse(BoardSources.isSourceSupplyTask(task("k", type: .counting, forkedFromTaskId: "x")))
    }

    // MARK: - Deletion cascade

    private func seedFork(_ db: AppDatabase) throws -> String {
        let forkId = BoardScopedFork.forkTaskId(boardId: "B2", taskId: "orig")
        try db.saveBoard(try board("B1"))
        try db.saveBoard(try board("B2"))
        try db.saveTask(task("orig"))
        try db.saveTask(task(forkId, createdInWizard: true, forkedFromTaskId: "orig"))
        try db.write { db in
            try self.placement("bt-orig", board: "B1", task: "orig").insert(db)
            try self.placement("bt-fork", board: "B2", task: forkId).insert(db)
            try self.completion("ev-orig", task: "orig").insert(db)
            try self.completion("ev-fork", task: forkId).insert(db)
        }
        return forkId
    }

    func testDeletingOriginalLeavesForkUntouched() throws {
        let db = try makeDb()
        let forkId = try seedFork(db)

        try db.deleteTaskWithCascade(taskId: "orig")

        let orig = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "orig") })
        XCTAssertTrue(orig.isDeleted)
        let fork = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: forkId) })
        XCTAssertFalse(fork.isDeleted)
        XCTAssertEqual(fork.version, 1)
        XCTAssertEqual(fork.forkedFromTaskId, "orig")
        let forkPlacement = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt-fork") })
        XCTAssertFalse(forkPlacement.isDeleted)
        XCTAssertEqual(forkPlacement.taskId, forkId)
        let forkEvent = try XCTUnwrap(try db.read { try TaskEvent.fetchOne($0, key: "ev-fork") })
        XCTAssertFalse(forkEvent.isDeleted)
    }

    func testImpactPreviewListsOnlyTheOriginalsBoard() throws {
        let db = try makeDb()
        _ = try seedFork(db)
        let impact = try db.computeTaskDeletionImpact(taskId: "orig")
        XCTAssertEqual(impact.boardTaskCount, 1)
        XCTAssertEqual(impact.affectedBoardIds, ["B1"])
    }

    func testDeletingForkLeavesOriginalUntouched() throws {
        let db = try makeDb()
        let forkId = try seedFork(db)

        try db.deleteTaskWithCascade(taskId: forkId)

        let fork = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: forkId) })
        XCTAssertTrue(fork.isDeleted)
        let forkPlacement = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt-fork") })
        XCTAssertTrue(forkPlacement.isDeleted)
        let orig = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "orig") })
        XCTAssertFalse(orig.isDeleted)
        XCTAssertEqual(orig.version, 1)
        let origPlacement = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt-orig") })
        XCTAssertFalse(origPlacement.isDeleted)
    }
}
