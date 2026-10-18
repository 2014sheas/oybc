import XCTest
import GRDB
@testable import OYBC

/// Forward-compatible pull (issue #300, ROADMAP Track L4; docs/SYNC_STRATEGY.md
/// §Forward-compatible pull). A doc written by a NEWER app version can carry an
/// enum value this build cannot decode. The contract under test:
///   1. never wedge — the doc is rolled out and ledgered, its batch siblings apply;
///   2. never lose — a later build re-fetches it by id (`sync_quarantine`);
///   3. never clobber — push is a merge write and an undecodable remote winner
///      is quarantined, not stored raw;
///   4. dependents (a placement of a quarantined task) are ledgered, not a
///      foreign-key failure that rolls the batch back.
/// Web twin: `apps/web/src/db/operations/__tests__/syncForwardCompat.test.ts`.
@MainActor
final class SyncForwardCompatTests: XCTestCase {

    private let userId = "u1"
    private let t0 = "2026-07-01T00:00:00.000Z"
    private let oldBuild = "0.9(1)"

    private let tasksCol: PullCollection = ("tasks", "tasks")
    private let boardsCol: PullCollection = ("boards", "boards")
    private let eventsCol: PullCollection = ("taskEvents", "task_events")
    private let placementsCol: PullCollection = ("boardTasks", "board_tasks")
    private let linksCol: PullCollection = ("compoundChildren", "compound_children")
    private let coreCol: PullCollection = ("coreBoardDefaults", "core_board_defaults")
    private let templatesCol: PullCollection = ("recurringBoardTemplates", "recurring_board_templates")

    // MARK: - Fixtures

    private func uuid(_ kind: Int, _ n: Int) -> String { PullFixture.uuid(kind, n) }

    /// `_syncedAt` for the n-th doc — strictly increasing, readable by `PullWatermark`.
    private func stamp(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + Double(n)) }

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        return db
    }

    private func makeSut(_ db: AppDatabase, source: FakePullSource = FakePullSource(docsByCollection: [:])) -> SyncService {
        SyncService(database: db, currentAuthUid: { [userId] in userId }, docStore: NullDocStore(), pullSource: source)
    }

    private func taskDoc(_ n: Int, type: String = "normal", title: String = "Secret title", operatorType: String? = nil) -> [String: Any] {
        var doc: [String: Any] = [
            "id": uuid(2, n), "userId": userId, "title": title, "type": type, "isCompleted": false,
            "totalCompletions": 0, "totalInstances": 0, "createdAt": t0, "updatedAt": t0, "version": 1,
            "isDeleted": false, "_syncedAt": stamp(n),
        ]
        if let operatorType { doc["operator"] = operatorType }
        return doc
    }

    private func boardDoc(_ n: Int, status: String = "active", timeframe: String = "daily") -> [String: Any] {
        [
            "id": uuid(1, n), "userId": userId, "name": "B\(n)", "status": status, "boardSize": 3,
            "timeframe": timeframe, "startDate": t0, "endDate": "2099-12-31T23:59:59.999Z",
            "centerSquareType": "none", "isRandomized": false, "totalTasks": 9, "completedTasks": 0,
            "linesCompleted": 0, "createdAt": t0, "updatedAt": t0, "version": 1, "isDeleted": false,
            "_syncedAt": stamp(n),
        ]
    }

    private func eventDoc(_ n: Int, taskId: String, kind: String = "completion") -> [String: Any] {
        [
            "id": uuid(4, n), "userId": userId, "taskId": taskId, "kind": kind, "occurredAt": t0,
            "createdAt": t0, "updatedAt": t0, "version": 1, "isDeleted": false, "_syncedAt": stamp(n),
        ]
    }

    private func placementDoc(_ n: Int, boardId: String, taskId: String, row: Int = 0, col: Int = 0, targetKind: String? = nil) -> [String: Any] {
        var doc: [String: Any] = [
            "id": uuid(3, n), "boardId": boardId, "taskId": taskId, "row": row, "col": col, "isCenter": false,
            "createdAt": t0, "updatedAt": t0, "version": 1, "isDeleted": false, "_syncedAt": stamp(n),
        ]
        if let targetKind { doc["targetKind"] = targetKind; doc["targetOverride"] = 5 }
        return doc
    }

    private func linkDoc(_ n: Int, parentId: String, childId: String) -> [String: Any] {
        [
            "id": uuid(5, n), "compoundTaskId": parentId, "childTaskId": childId, "childIndex": 0,
            "createdAt": t0, "updatedAt": t0, "version": 1, "isDeleted": false, "_syncedAt": stamp(n),
        ]
    }

    private func coreDoc(_ n: Int, timeframe: String) -> [String: Any] {
        [
            "id": uuid(6, n), "userId": userId, "timeframe": timeframe, "createdAt": t0, "updatedAt": t0,
            "version": 1, "isDeleted": false, "_syncedAt": stamp(n),
        ]
    }

    private func templateDoc(_ n: Int, timeframe: String) -> [String: Any] {
        [
            "id": uuid(7, n), "userId": userId, "name": "R\(n)", "timeframe": timeframe, "boardSize": 3,
            "centerSquareType": "none", "isRandomized": false, "isActive": true, "createdAt": t0,
            "updatedAt": t0, "version": 1, "isDeleted": false, "_syncedAt": stamp(n),
        ]
    }

    @discardableResult
    private func apply(_ db: AppDatabase, _ collection: PullCollection, _ docs: [[String: Any]], checkpoint: Bool = true) async throws -> PullBatchOutcome {
        try await db.applyPullBatch(collection: collection, docs: PullDocs(docs: docs), userId: userId, checkpoint: checkpoint)
    }

    private func ledger(_ db: AppDatabase) throws -> [QuarantinedDoc] {
        try db.read { try AppDatabase.fetchQuarantinedDocs(db: $0, userId: self.userId) }
    }

    private func count(_ db: AppDatabase, _ table: String) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    private func watermarks(_ db: AppDatabase) throws -> [String: PullWatermark] {
        try db.read { try AppDatabase.fetchSyncWatermarks(db: $0, userId: self.userId) }
    }

    /// Every typed model of every synced table still reads — the invariant a
    /// quarantined doc must never break (a raw undecodable row would throw here).
    private func assertEveryTableReadable(_ db: AppDatabase, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try db.read { try Task.fetchAll($0) }, "tasks", file: file, line: line)
        XCTAssertNoThrow(try db.read { try Board.fetchAll($0) }, "boards", file: file, line: line)
        XCTAssertNoThrow(try db.read { try BoardTask.fetchAll($0) }, "board_tasks", file: file, line: line)
        XCTAssertNoThrow(try db.read { try CompoundChild.fetchAll($0) }, "compound_children", file: file, line: line)
        XCTAssertNoThrow(try db.read { try TaskEvent.fetchAll($0) }, "task_events", file: file, line: line)
        XCTAssertNoThrow(try db.read { try RecurringBoardTemplate.fetchAll($0) }, "recurring_board_templates", file: file, line: line)
        XCTAssertNoThrow(try db.read { try Pool.fetchAll($0) }, "pools", file: file, line: line)
        XCTAssertNoThrow(try db.read { try CoreBoardDefault.fetchAll($0) }, "core_board_defaults", file: file, line: line)
    }

    /// Rewrites every ledger row as if an EARLIER build had recorded it.
    private func ledgerAsOldBuild(_ db: AppDatabase) throws {
        try db.write { try $0.execute(sql: "UPDATE sync_quarantine SET appBuild = ?", arguments: [self.oldBuild]) }
    }

    // MARK: - 1. Never wedge

    func test_futureTypedTask_siblingsApply_docLedgered_checkpointAdvances_andIsNotRetriedForever() async throws {
        let db = try makeDb()
        let batch = [taskDoc(1), taskDoc(2, type: "habit", title: "Secret title"), taskDoc(3)]

        let first = try await apply(db, tasksCol, batch)

        XCTAssertEqual(first.pulled, 2, "the two decodable siblings applied")
        XCTAssertEqual(try count(db, "tasks"), 2, "the future-typed row is not left in the table")
        let rows = try ledger(db)
        XCTAssertEqual(rows.map(\.docId), [uuid(2, 2)])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.collection, "tasks")
        XCTAssertTrue(row.reason.hasPrefix("undecodable: could not decode TaskType"), row.reason)
        XCTAssertFalse(row.reason.contains("Secret title") || row.reason.contains(userId), "no row dump / uid in the reason: \(row.reason)")
        XCTAssertEqual(row.appBuild, AppDatabase.currentAppBuild)
        XCTAssertEqual(try watermarks(db)["tasks"], PullWatermark(syncedAtValue: stamp(3)), "the checkpoint moved past the ledgered doc")
        assertEveryTableReadable(db)
        XCTAssertTrue(first.details.contains { $0.hasPrefix("Quarantined tasks/\(uuid(2, 2))") })

        // The same batch again (a re-delivery) neither throws nor duplicates.
        let second = try await apply(db, tasksCol, batch)
        XCTAssertEqual(second.pulled, 0)
        XCTAssertEqual(try ledger(db).count, 1)
        XCTAssertEqual(try count(db, "tasks"), 2)
    }

    /// Every enum a newer build can widen. Each future doc is ledgered while its
    /// valid sibling in the same batch applies and every typed read keeps working
    /// (the pre-fix behaviour: batch rollback for tasks / boards / events, a
    /// poisoned table for core defaults / templates).
    func test_unknownEnumValue_inEveryCollection_isLedgered_andSiblingsApply() async throws {
        struct Case { let name: String; let col: PullCollection; let table: String; let valid: [String: Any]; let future: [String: Any] }
        let cases: [Case] = [
            Case(name: "tasks.type", col: tasksCol, table: "tasks", valid: taskDoc(10), future: taskDoc(11, type: "habit")),
            Case(name: "boards.status", col: boardsCol, table: "boards", valid: boardDoc(10), future: boardDoc(11, status: "paused")),
            Case(name: "boards.timeframe", col: boardsCol, table: "boards", valid: boardDoc(10), future: boardDoc(11, timeframe: "quarterly")),
            Case(name: "taskEvents.kind", col: eventsCol, table: "task_events", valid: eventDoc(10, taskId: uuid(2, 1)), future: eventDoc(11, taskId: uuid(2, 1), kind: "decrement")),
            Case(name: "coreBoardDefaults.timeframe", col: coreCol, table: "core_board_defaults", valid: coreDoc(10, timeframe: "daily"), future: coreDoc(11, timeframe: "quarterly")),
            Case(name: "recurringBoardTemplates.timeframe", col: templatesCol, table: "recurring_board_templates", valid: templateDoc(10, timeframe: "weekly"), future: templateDoc(11, timeframe: "quarterly")),
        ]
        for c in cases {
            let db = try makeDb()
            let outcome = try await apply(db, c.col, [c.valid, c.future])
            XCTAssertEqual(outcome.pulled, 1, c.name)
            XCTAssertEqual(try count(db, c.table), 1, "\(c.name): only the valid sibling is stored")
            XCTAssertEqual(try ledger(db).map(\.collection), [c.col.firestoreName], c.name)
            XCTAssertEqual(try ledger(db).map(\.docId), [c.future["id"] as? String], c.name)
            XCTAssertEqual(try watermarks(db)[c.col.firestoreName], PullWatermark(syncedAtValue: c.future["_syncedAt"]), "\(c.name): checkpoint advanced")
            assertEveryTableReadable(db)
        }
    }

    /// A placement parameter this build doesn't know is TOLERATED by the model
    /// (decoded as absent), not quarantined — the placement still applies.
    func test_unknownPlacementTargetKind_isTolerated_notQuarantined() async throws {
        let db = try makeDb()
        try await apply(db, boardsCol, [boardDoc(1)])
        try await apply(db, tasksCol, [taskDoc(1)])

        let outcome = try await apply(db, placementsCol, [placementDoc(1, boardId: uuid(1, 1), taskId: uuid(2, 1), targetKind: "quantum")])

        XCTAssertEqual(outcome.pulled, 1)
        XCTAssertEqual(try ledger(db).count, 0)
        let stored = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: self.uuid(3, 1)) })
        XCTAssertNil(stored.targetKind, "the unknown kind decodes as absent (= the task's own kind)")
        XCTAssertEqual(stored.targetOverride, 5)
    }

    // MARK: - 2. Dependents

    func test_placementOfAQuarantinedTask_isLedgeredAsDependent_notAForeignKeyFailure() async throws {
        let db = try makeDb()
        try await apply(db, boardsCol, [boardDoc(1)])
        try await apply(db, tasksCol, [taskDoc(1, type: "habit"), taskDoc(2)])

        let outcome = try await apply(db, placementsCol, [
            placementDoc(1, boardId: uuid(1, 1), taskId: uuid(2, 1), row: 0, col: 0),
            placementDoc(2, boardId: uuid(1, 1), taskId: uuid(2, 2), row: 0, col: 1),
        ])

        XCTAssertEqual(outcome.pulled, 1, "the placement of the readable task applied")
        XCTAssertEqual(try count(db, "board_tasks"), 1)
        let dependent = try XCTUnwrap(try ledger(db).first { $0.collection == "boardTasks" })
        XCTAssertEqual(dependent.docId, uuid(3, 1))
        XCTAssertEqual(dependent.reason, "depends on quarantined tasks/\(uuid(2, 1))")
        assertEveryTableReadable(db)
    }

    func test_placementOnAQuarantinedBoard_isLedgeredAsDependent() async throws {
        let db = try makeDb()
        try await apply(db, boardsCol, [boardDoc(1, status: "paused")])
        try await apply(db, tasksCol, [taskDoc(1)])

        let outcome = try await apply(db, placementsCol, [placementDoc(1, boardId: uuid(1, 1), taskId: uuid(2, 1))])

        XCTAssertEqual(outcome.pulled, 0)
        XCTAssertEqual(try ledger(db).first { $0.collection == "boardTasks" }?.reason, "depends on quarantined boards/\(uuid(1, 1))")
    }

    /// A missing reference that is NOT quarantined is the ordinary ordering race:
    /// it keeps its old behaviour (the batch rolls back and the next pull retries)
    /// — quarantine never swallows a doc that would simply apply a moment later.
    func test_placementWithAnUnknownMissingTask_stillRollsBackForTheNextPull() async throws {
        let db = try makeDb()
        try await apply(db, boardsCol, [boardDoc(1)])

        do {
            try await apply(db, placementsCol, [placementDoc(1, boardId: uuid(1, 1), taskId: uuid(2, 99))])
            XCTFail("expected the foreign-key failure to roll the batch back")
        } catch {
            XCTAssertTrue(error is DatabaseError, "\(error)")
        }
        XCTAssertEqual(try count(db, "board_tasks"), 0)
        XCTAssertEqual(try ledger(db).count, 0)
        XCTAssertNil(try watermarks(db)["boardTasks"], "no checkpoint — the doc is re-read")
    }

    func test_compoundLink_toAQuarantinedChild_andToAMissingParent_areLedgered() async throws {
        let db = try makeDb()
        try await apply(db, tasksCol, [
            taskDoc(1, type: "compound", operatorType: "AND"), taskDoc(2, type: "habit"), taskDoc(3),
        ])

        let outcome = try await apply(db, linksCol, [
            linkDoc(1, parentId: uuid(2, 1), childId: uuid(2, 2)), // child quarantined
            linkDoc(2, parentId: uuid(2, 1), childId: uuid(2, 3)), // fine
            linkDoc(3, parentId: uuid(2, 50), childId: uuid(2, 3)), // parent not local
        ])

        XCTAssertEqual(outcome.pulled, 1)
        XCTAssertEqual(try count(db, "compound_children"), 1)
        let byId = Dictionary(uniqueKeysWithValues: try ledger(db).filter { $0.collection == "compoundChildren" }.map { ($0.docId, $0.reason) })
        XCTAssertEqual(byId[uuid(5, 1)], "depends on quarantined tasks/\(uuid(2, 2))")
        XCTAssertEqual(byId[uuid(5, 3)], AppDatabase.orphanedChildReason)
        XCTAssertNil(byId[uuid(5, 2)])
    }

    /// Items 4 / L4: a square whose task this build cannot read is simply an
    /// incomplete cell — never counted, never a crash, never a greenlog.
    func test_derivation_treatsAPlacementWhoseTaskIsMissingAsAnIncompleteCell() throws {
        let board = try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: [
            "id": uuid(1, 1), "userId": userId, "name": "B", "status": "active", "boardSize": 3,
            "timeframe": "daily", "startDate": t0, "centerSquareType": "none", "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0, "createdAt": t0, "updatedAt": t0,
            "version": 1, "isDeleted": false,
        ] as [String: Any]))
        var placements: [BoardTask] = []
        var tasks: [String: Task] = [:]
        for n in 0..<9 {
            let id = uuid(2, n)
            placements.append(BoardTask(id: uuid(3, n), boardId: board.id, taskId: id, row: n / 3, col: n % 3,
                                        isCenter: false, createdAt: t0, updatedAt: t0, lastSyncedAt: nil, version: 1))
            guard n != 4 else { continue } // the future-typed task: never stored
            var task = try JSONDecoder().decode(Task.self, from: JSONSerialization.data(withJSONObject: [
                "id": id, "userId": userId, "title": "T\(n)", "type": "normal", "totalCompletions": 0,
                "totalInstances": 0, "isCompleted": true, "createdAt": t0, "updatedAt": t0, "version": 1,
                "isDeleted": false,
            ] as [String: Any]))
            task.isCompleted = true
            tasks[id] = task
        }

        let update = DerivationPass.computeBoardStatsUpdate(
            board: board, boardTasksOnBoard: placements, childrenByCompound: [:], taskById: tasks, windowContext: nil
        )

        XCTAssertEqual(update.completedTasks, 8, "the unreadable square is not counted")
        XCTAssertLessThan(update.completedTasks, board.boardSize * board.boardSize, "so the board can never greenlog from it")
    }

    // MARK: - 3. Never lose: retry on a new build

    /// A remote with a future-typed task T (stamped BEFORE the task checkpoint),
    /// its placement P on a board, and a normal task N that moves the checkpoint
    /// past T. `blocked` flips T to a type this build understands — "the app updated".
    private func makeRemote() -> (source: FakePullSource, taskId: String, placementId: String, understood: [String: Any]) {
        let future = taskDoc(1, type: "habit")
        let normal = taskDoc(2)
        let source = FakePullSource(docsByCollection: [
            "boards": [boardDoc(3)],
            "tasks": [future, normal],
            "boardTasks": [placementDoc(4, boardId: uuid(1, 3), taskId: uuid(2, 1)), placementDoc(5, boardId: uuid(1, 3), taskId: uuid(2, 2), row: 0, col: 1)],
        ])
        var understood = future
        understood["type"] = "normal"
        return (source, uuid(2, 1), uuid(3, 4), understood)
    }

    func test_sameBuild_neverRefetchesAQuarantinedDoc() async throws {
        let db = try makeDb()
        let (source, taskId, placementId, _) = makeRemote()
        let sut = makeSut(db, source: source)

        _ = await sut.pullSync(userId: userId, lastSyncedAt: nil)
        XCTAssertEqual(try ledger(db).map(\.docId).sorted(), [taskId, placementId].sorted())
        XCTAssertEqual(source.documentFetches, [])

        _ = await sut.pullSync(userId: userId, lastSyncedAt: nil)
        XCTAssertEqual(source.documentFetches, [], "an unchanged build must not re-read a doc it already failed on")
        XCTAssertEqual(try count(db, "tasks"), 1)
        XCTAssertEqual(try count(db, "board_tasks"), 1, "only the placement of the readable task")
    }

    func test_newBuild_refetchesQuarantinedDocs_andTheirDependents_inApplyOrder() async throws {
        let db = try makeDb()
        let (source, taskId, placementId, understood) = makeRemote()
        let sut = makeSut(db, source: source)
        _ = await sut.pullSync(userId: userId, lastSyncedAt: nil)
        XCTAssertEqual(try ledger(db).count, 2)
        let taskCheckpoint = try XCTUnwrap(try watermarks(db)["tasks"])
        XCTAssertGreaterThan(taskCheckpoint, PullWatermark(syncedAtValue: stamp(1))!, "the checkpoint is past the ledgered task — only the ledger can recover it")

        // The app updates: the build changes and the new build understands the type.
        try ledgerAsOldBuild(db)
        source.replace(understood, in: "tasks")
        let result = await sut.pullSync(userId: userId, lastSyncedAt: nil)

        XCTAssertEqual(source.documentFetches, ["tasks/\(taskId)", "boardTasks/\(placementId)"], "the task first, then its placement")
        XCTAssertEqual(try ledger(db).count, 0, "both released")
        XCTAssertEqual(try count(db, "tasks"), 2)
        XCTAssertEqual(try count(db, "board_tasks"), 2)
        XCTAssertGreaterThanOrEqual(result.pulled, 2)
        XCTAssertTrue(result.details.contains { $0.hasPrefix("Retry Pulled tasks/\(taskId)") }, "\(result.details)")
        assertEveryTableReadable(db)
        let board = try XCTUnwrap(try db.fetchBoard(id: uuid(1, 3)))
        XCTAssertEqual(board.status, .active)
    }

    func test_newBuild_docStillUndecodable_staysLedgered_andIsNotRefetchedAgainUnderThatBuild() async throws {
        let db = try makeDb()
        let (source, taskId, _, _) = makeRemote()
        let sut = makeSut(db, source: source)
        _ = await sut.pullSync(userId: userId, lastSyncedAt: nil)
        try ledgerAsOldBuild(db)

        _ = await sut.pullSync(userId: userId, lastSyncedAt: nil)
        XCTAssertEqual(source.documentFetches.filter { $0 == "tasks/\(taskId)" }.count, 1)
        let row = try XCTUnwrap(try ledger(db).first { $0.docId == taskId })
        XCTAssertEqual(row.appBuild, AppDatabase.currentAppBuild, "re-stamped by the build that tried it")

        _ = await sut.pullSync(userId: userId, lastSyncedAt: nil)
        XCTAssertEqual(source.documentFetches.filter { $0 == "tasks/\(taskId)" }.count, 1, "not again under the same build")
    }

    func test_newBuild_docGoneFromTheServer_isReleased() async throws {
        let db = try makeDb()
        try await apply(db, tasksCol, [taskDoc(1, type: "habit")])
        try ledgerAsOldBuild(db)
        let source = FakePullSource(docsByCollection: [:])

        _ = await makeSut(db, source: source).pullSync(userId: userId, lastSyncedAt: nil)

        XCTAssertEqual(source.documentFetches, ["tasks/\(uuid(2, 1))"])
        XCTAssertEqual(try ledger(db).count, 0)
    }

    func test_retryPass_isCappedPerPull() async throws {
        let db = try makeDb()
        try await apply(db, tasksCol, [taskDoc(1, type: "habit"), taskDoc(2, type: "habit"), taskDoc(3, type: "habit")])
        try ledgerAsOldBuild(db)
        let source = FakePullSource(docsByCollection: [:])

        _ = try await db.retryQuarantinedPullDocs(source: source, userId: userId, appBuild: "1.0(2)", limit: 2)

        XCTAssertEqual(source.documentFetches.count, 2)
        XCTAssertEqual(try ledger(db).count, 1, "the third row waits for the next pull")
    }

    func test_retryTransportFailure_doesNotFailThePull_andKeepsTheLedger() async throws {
        let db = try makeDb()
        try await apply(db, tasksCol, [taskDoc(1, type: "habit")])
        try ledgerAsOldBuild(db)
        let source = FakePullSource(docsByCollection: ["tasks": [taskDoc(5)]])
        source.failDocumentFetch = true

        let result = await makeSut(db, source: source).pullSync(userId: userId, lastSyncedAt: nil)

        XCTAssertTrue(result.details.contains { $0.hasPrefix("Quarantine retry skipped") })
        XCTAssertFalse(result.details.contains { $0.contains("Pull failed") }, "the ordinary pull still ran and finished cleanly")
        XCTAssertEqual(try count(db, "tasks"), 1)
        XCTAssertEqual(try ledger(db).first?.appBuild, oldBuild, "untouched — retried on the next pull")
    }

    func test_aQuarantinedDocThatArrivesDecodable_isReleasedByTheOrdinaryPull() async throws {
        let db = try makeDb()
        try await apply(db, tasksCol, [taskDoc(1, type: "habit")])
        XCTAssertEqual(try ledger(db).count, 1)

        var fixed = taskDoc(1)
        fixed["version"] = 2
        try await apply(db, tasksCol, [fixed], checkpoint: false)

        XCTAssertEqual(try ledger(db).count, 0)
        XCTAssertEqual(try count(db, "tasks"), 1)
    }

    /// A completed task with no live event looks like a fresh-install backfill gap
    /// the heal would repair by minting a completion — but an event this build
    /// could not read may be that very completion, so the heal waits.
    func test_healOnPull_neverMintsOverAnUnreadableEvent_thenResumes() async throws {
        let db = try makeDb()
        var completed = taskDoc(1)
        completed["isCompleted"] = true
        try await apply(db, tasksCol, [completed])
        try await apply(db, eventsCol, [eventDoc(1, taskId: uuid(2, 1), kind: "decrement")])
        XCTAssertEqual(try ledger(db).map(\.collection), ["taskEvents"])
        let sut = makeSut(db)

        XCTAssertEqual(sut.healMissingCompletionEvents(userId: userId), 0)
        XCTAssertEqual(try count(db, "task_events"), 0)

        try db.write { try AppDatabase.releaseQuarantinedDocs(db: $0, userId: self.userId, collection: "taskEvents", ids: [self.uuid(4, 1)]) }
        XCTAssertEqual(sut.healMissingCompletionEvents(userId: userId), 1)
    }

    // MARK: - 4. Never clobber (push)

    /// `FirestoreDocStore.write` is a MERGE (`setData(merge: true)`): this fake
    /// merges too, so keys the local model doesn't carry survive a push.
    private final class MergingDocStore: FirestoreDocStore {
        var docs: [String: [String: Any]] = [:]
        func fetch(path: String) async throws -> [String: Any]? { docs[path] }
        func write(path: String, data: [String: Any]) async throws {
            docs[path, default: [:]].merge(data) { _, new in new }
        }
    }

    private func localTask(id: String, version: Int, title: String) -> Task {
        Task(
            id: id, userId: userId, title: title, description: nil, type: .normal, action: nil, unit: nil,
            maxCount: nil, operatorType: nil, threshold: nil, referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil, totalCompletions: 0, totalInstances: 0, isCompleted: false,
            completedAt: nil, currentCount: nil, createdAt: t0, updatedAt: "2026-07-05T00:00:00.000Z",
            lastSyncedAt: nil, version: version, isDeleted: false, deletedAt: nil, timeframe: nil, startDate: nil,
            endDate: nil, sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false, isCounter: false
        )
    }

    private func enqueue(_ task: Task, in db: AppDatabase) throws {
        try db.write { try task.save($0) }
        try db.saveSyncItem(SyncQueueBuilder.makeItem(
            entityType: "tasks", entityId: task.id, operationType: .update, payload: task, now: AppDatabase.currentTimestamp()
        ))
    }

    func test_push_isAMerge_soFieldsANewerClientAddedSurviveAnOlderClientsEdit() async throws {
        let db = try makeDb()
        let id = uuid(2, 1)
        let store = MergingDocStore()
        store.docs["users/\(userId)/tasks/\(id)"] = [
            "id": id, "userId": userId, "title": "remote", "type": "normal", "version": 1, "updatedAt": t0,
            "futureField": "kept", "futureNested": ["a": 1],
        ]
        try enqueue(localTask(id: id, version: 2, title: "edited by the older client"), in: db)

        let result = await SyncService(database: db, currentAuthUid: { [userId] in userId }, docStore: store).pushSync(userId: userId)

        XCTAssertEqual(result.pushed, 1)
        let remote = try XCTUnwrap(store.docs["users/\(userId)/tasks/\(id)"])
        XCTAssertEqual(remote["title"] as? String, "edited by the older client")
        XCTAssertEqual(remote["futureField"] as? String, "kept", "an unknown remote field is not erased")
        XCTAssertNotNil(remote["futureNested"])
    }

    func test_push_remoteWinnerThisBuildCannotDecode_isQuarantined_notStoredRaw() async throws {
        let db = try makeDb()
        let id = uuid(2, 1)
        let store = MergingDocStore()
        store.docs["users/\(userId)/tasks/\(id)"] = [
            "id": id, "userId": userId, "title": "from the future", "type": "habit", "version": 9,
            "updatedAt": "2026-07-09T00:00:00.000Z", "createdAt": t0, "isDeleted": false,
        ]
        try enqueue(localTask(id: id, version: 2, title: "local"), in: db)

        let result = await SyncService(database: db, currentAuthUid: { [userId] in userId }, docStore: store).pushSync(userId: userId)

        XCTAssertEqual(result.conflicts, 1)
        let local = try XCTUnwrap(try db.fetchTask(id: id))
        XCTAssertEqual(local.type, .normal, "the readable local row is untouched")
        XCTAssertEqual(local.title, "local")
        XCTAssertEqual(try ledger(db).map(\.docId), [id])
        XCTAssertEqual(store.docs["users/\(userId)/tasks/\(id)"]?["title"] as? String, "from the future", "and nothing was written over the remote")
        assertEveryTableReadable(db)
    }

    // MARK: - 5. Guards

    /// Every foreign key into `tasks` / `boards` on a synced table needs a
    /// `quarantinedDependencyReason` case (a dependent of a quarantined doc would
    /// otherwise fail its insert and roll its batch back). A new FK fails here.
    func test_foreignKeysIntoTasksAndBoards_areExactlyTheOnesTheQuarantineHandles() throws {
        let db = try makeDb()
        let tables = try db.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") }
        var found: Set<String> = []
        try db.read { database in
            for table in tables {
                for fk in try Row.fetchAll(database, sql: "PRAGMA foreign_key_list(\"\(table)\")") {
                    let parent: String = fk["table"]
                    if parent == "tasks" || parent == "boards" { found.insert("\(table).\(fk["from"] as String)->\(parent)") }
                }
            }
        }
        XCTAssertEqual(found, [
            "board_tasks.boardId->boards", "board_tasks.taskId->tasks",
            "compound_children.compoundTaskId->tasks", "compound_children.childTaskId->tasks",
        ], "update AppDatabase.quarantinedDependencyReason (and this list) for the new foreign key")
    }

    func test_quarantineTable_isLocalOnly_andWiped() throws {
        XCTAssertTrue(AuthService.userScopedTables.contains("sync_quarantine"))
        XCTAssertFalse(syncableCollections.contains { $0.grdbTable == "sync_quarantine" }, "never a sync collection")
    }
}
