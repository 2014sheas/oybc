import XCTest
import GRDB
@testable import OYBC

/// The launch-watchdog fix (2026-10-07): the pull applies in batches OFF the
/// main actor, cascades once per batch, checkpoints each collection in
/// dependency order, and attaches listeners only after the first pull.
///
/// Expected board stats come from `PullFixture`'s construction (3 completed
/// cells per board → 1 line, `row_0`), never from re-running the code under
/// test.
@MainActor
final class SyncPullBatchTests: XCTestCase {

    private let userId = PullFixture.userId
    private let tasksCol: PullCollection = ("tasks", "tasks")
    private let eventsCol: PullCollection = ("taskEvents", "task_events")
    private let boardsCol: PullCollection = ("boards", "boards")
    private let boardTasksCol: PullCollection = ("boardTasks", "board_tasks")

    override func setUp() {
        super.setUp()
        AppDatabase.pullCascadeLookupLoads = 0
        AppDatabase.onPullBatchTransaction = nil
    }

    override func tearDown() {
        AppDatabase.onPullBatchTransaction = nil
        super.tearDown()
    }

    // MARK: - Fixtures

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

    private func makeSut(_ db: AppDatabase, source: FakePullSource) -> SyncService {
        SyncService(database: db, currentAuthUid: { [userId] in userId }, docStore: NullDocStore(), pullSource: source)
    }

    private func watermarks(_ db: AppDatabase) throws -> [String: PullWatermark] {
        try db.read { try AppDatabase.fetchSyncWatermarks(db: $0, userId: self.userId) }
    }

    private func count(_ db: AppDatabase, _ table: String) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    private func assertEveryBoardDerived(_ db: AppDatabase, _ fixture: PullFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        for id in fixture.boardIds {
            let board = try XCTUnwrap(try db.fetchBoard(id: id), file: file, line: line)
            XCTAssertEqual(board.completedTasks, PullFixture.expectedCompleted, "board \(id)", file: file, line: line)
            XCTAssertEqual(board.linesCompleted, 1, "board \(id)", file: file, line: line)
            XCTAssertEqual(board.completedLineIds, PullFixture.expectedLineIds, "board \(id)", file: file, line: line)
        }
    }

    // MARK: - (a) one cascade per batch

    func test_batchApply_buildsCascadeLookupsOncePerBatch_andDerivesEveryBoard() async throws {
        let db = try makeDb()
        let fixture = PullFixture(boards: 6) // 54 tasks, 54 placements, 18 events
        let docs = fixture.docs

        _ = try await db.applyPullBatch(collection: tasksCol, docs: PullDocs(docs: docs["tasks"]!), userId: userId, checkpoint: true)
        XCTAssertEqual(AppDatabase.pullCascadeLookupLoads, 1, "54 tasks → ONE lookup load (the per-doc path did 54)")

        AppDatabase.pullCascadeLookupLoads = 0
        _ = try await db.applyPullBatch(collection: eventsCol, docs: PullDocs(docs: docs["taskEvents"]!), userId: userId, checkpoint: true)
        XCTAssertLessThanOrEqual(AppDatabase.pullCascadeLookupLoads, 1)

        _ = try await db.applyPullBatch(collection: boardsCol, docs: PullDocs(docs: docs["boards"]!), userId: userId, checkpoint: true)

        AppDatabase.pullCascadeLookupLoads = 0
        let placements = try await db.applyPullBatch(collection: boardTasksCol, docs: PullDocs(docs: docs["boardTasks"]!), userId: userId, checkpoint: true)
        XCTAssertEqual(placements.pulled, 54)
        XCTAssertEqual(AppDatabase.pullCascadeLookupLoads, 1, "54 placements on 6 boards → ONE lookup load")

        try assertEveryBoardDerived(db, fixture)
    }

    func test_singleBoardTaskCascadeWrapper_stillDerivesItsBoard() async throws {
        let db = try makeDb()
        let fixture = PullFixture(boards: 1)
        for name in ["tasks", "taskEvents", "boards"] {
            _ = try await db.applyPullBatch(collection: (name, syncableCollections.first { $0.firestoreName == name }!.grdbTable),
                                            docs: PullDocs(docs: fixture.docs[name]!), userId: userId, checkpoint: false)
        }
        // Placements one doc at a time through the 1-doc sync seam.
        let sut = makeSut(db, source: FakePullSource(docsByCollection: [:]))
        for doc in fixture.docs["boardTasks"]! {
            XCTAssertTrue(sut.applyRemoteSubdoc(collection: boardTasksCol, remoteData: doc, authenticatedUserId: userId))
        }
        try assertEveryBoardDerived(db, fixture)
    }

    // MARK: - (b) the apply runs off the main thread

    func test_batchTransaction_runsOffTheMainThread() async throws {
        XCTAssertTrue(Thread.isMainThread, "precondition: the test (like SyncService) runs on the main actor")
        let db = try makeDb()
        let fixture = PullFixture(boards: 2)
        var onMain: [Bool] = []
        let lock = NSLock()
        AppDatabase.onPullBatchTransaction = { _ in lock.withLock { onMain.append(Thread.isMainThread) } }

        let sut = makeSut(db, source: FakePullSource(docsByCollection: fixture.docs))
        _ = await sut.pullSync(userId: userId, lastSyncedAt: nil)

        let recorded = lock.withLock { onMain }
        XCTAssertFalse(recorded.isEmpty, "the hook never fired")
        XCTAssertEqual(recorded.filter { $0 }.count, 0, "a batch transaction ran on the main thread")
        try assertEveryBoardDerived(db, fixture)
    }

    // MARK: - (c) checkpoints + resume

    func test_pullInterruptedAtBoards_checkpointsEarlierCollections_andResumeSkipsThem() async throws {
        let db = try makeDb()
        let fixture = PullFixture(boards: 4)

        // Run 1: `boards` fails (offline mid-pull). Order is boards →
        // taskEvents → tasks → compoundChildren → boardTasks → …
        let failing = FakePullSource(docsByCollection: fixture.docs, failCollection: "boards")
        let first = await makeSut(db, source: failing).pullSync(userId: userId, lastSyncedAt: nil)
        XCTAssertTrue(first.details.contains { $0.contains("Pull failed for boards") })
        XCTAssertEqual(failing.fetches.map(\.collection), pullApplyOrder, "every collection is attempted, in dependency order")

        var marks = try watermarks(db)
        XCTAssertEqual(marks["tasks"], fixture.maxSyncedAt("tasks"))
        XCTAssertEqual(marks["taskEvents"], fixture.maxSyncedAt("taskEvents"))
        XCTAssertNil(marks["boards"], "a failed collection must not checkpoint")
        // boardTasks came after the failure: its rows reference boards that
        // aren't local (FK), so its batch rolls back — rows AND checkpoint.
        XCTAssertTrue(first.details.contains { $0.contains("Pull failed for boardTasks") })
        XCTAssertNil(marks["boardTasks"])
        XCTAssertEqual(try count(db, "board_tasks"), 0)
        XCTAssertNil(try db.fetchUser(id: userId)?.lastSyncedAt, "a partial pull never stamps lastSyncedAt")

        // Run 2: nothing fails. Checkpointed collections resume from their
        // checkpoint (only the `>=` boundary doc comes back, an echo).
        let resuming = FakePullSource(docsByCollection: fixture.docs)
        let second = await makeSut(db, source: resuming).pullSync(userId: userId, lastSyncedAt: nil)
        let since = Dictionary(uniqueKeysWithValues: resuming.fetches.map { ($0.collection, $0.since) })
        XCTAssertEqual(since["tasks"] ?? nil, fixture.maxSyncedAt("tasks"))
        XCTAssertEqual(since["taskEvents"] ?? nil, fixture.maxSyncedAt("taskEvents"))
        XCTAssertNil(since["boards"] ?? nil, "boards had no checkpoint → full read")
        XCTAssertNil(since["boardTasks"] ?? nil)
        XCTAssertFalse(second.details.contains { $0.hasPrefix("Pulled tasks/") }, "tasks re-applied on resume")
        XCTAssertFalse(second.details.contains { $0.hasPrefix("Pulled taskEvents/") }, "events re-applied on resume")
        XCTAssertEqual(second.details.filter { $0.hasPrefix("Pulled boards/") }.count, fixture.boardIds.count)

        marks = try watermarks(db)
        XCTAssertEqual(marks["boards"], fixture.maxSyncedAt("boards"))
        XCTAssertNotNil(try db.fetchUser(id: userId)?.lastSyncedAt, "a clean pull stamps lastSyncedAt")
        // Converges to the uninterrupted result.
        try assertEveryBoardDerived(db, fixture)
    }

    func test_throwMidBatch_rollsBackTheWholeBatchAndItsCheckpoint() async throws {
        let db = try makeDb()
        var docs = PullFixture(boards: 1).docs["tasks"]!
        // Passes validation, upserts raw, then the cascade's decode throws.
        var poison = docs[0]
        poison["id"] = PullFixture.uuid(9, 1)
        poison["type"] = "not_a_real_type"
        docs.append(poison)

        do {
            _ = try await db.applyPullBatch(collection: tasksCol, docs: PullDocs(docs: docs), userId: userId, checkpoint: true)
            XCTFail("the poisoned batch should throw")
        } catch {}

        XCTAssertEqual(try count(db, "tasks"), 0, "good docs in the same batch must roll back too")
        XCTAssertTrue(try watermarks(db).isEmpty, "the checkpoint must roll back with the batch")
    }

    func test_checkpointNeverMovesBackwards() async throws {
        let db = try makeDb()
        let fixture = PullFixture(boards: 1)
        let tasks = fixture.docs["tasks"]!
        _ = try await db.applyPullBatch(collection: tasksCol, docs: PullDocs(docs: tasks), userId: userId, checkpoint: true)
        _ = try await db.applyPullBatch(collection: tasksCol, docs: PullDocs(docs: [tasks[0]]), userId: userId, checkpoint: true)
        XCTAssertEqual(try watermarks(db)["tasks"], fixture.maxSyncedAt("tasks"))
    }

    func test_checkpointChunks_areSyncedAtOrdered_withMissingStampsFirst() async {
        var docs: [[String: Any]] = (0..<(AppDatabase.pullChunkSize + 3)).reversed().map {
            ["id": "d\($0)", "_syncedAt": Date(timeIntervalSince1970: TimeInterval(1_000 + $0))]
        }
        docs.append(["id": "legacy"]) // a pre-`_syncedAt` doc
        let chunks = await SyncService.checkpointChunks(PullDocs(docs: docs))
        XCTAssertEqual(chunks.map(\.docs.count), [AppDatabase.pullChunkSize, 4])
        XCTAssertEqual(chunks[0].docs.first?["id"] as? String, "legacy")
        let marks = chunks.flatMap(\.docs).compactMap { PullWatermark(syncedAtValue: $0["_syncedAt"]) }
        XCTAssertEqual(marks, marks.sorted())
    }

    // MARK: - Boards first, events before task rows (review C1)

    /// A peer completed a square AND renamed the board: the pull brings the
    /// completion event, the authored Task row (caches) and board v2 with the
    /// new name + new stats. Applying the event or task batch against the stale
    /// local board v1 would author a bump that out-ranks v2 under LWW (stale
    /// name pushed back), or bump twice. Boards → events → tasks: nothing is
    /// authored, the remote board wins verbatim.
    func test_remoteCompletionPlusRename_appliesTheRemoteBoard_andAuthorsNothing() async throws {
        let db = try makeDb()
        var fixture = PullFixture(boards: 1).docs
        fixture["tasks"] = fixture["tasks"]!.map { var t = $0; t["isCompleted"] = false; return t }
        for name in ["boards", "tasks", "boardTasks"] {
            _ = try await db.applyPullBatch(collection: (name, syncableCollections.first { $0.firestoreName == name }!.grdbTable),
                                            docs: PullDocs(docs: fixture[name]!), userId: userId, checkpoint: false)
        }
        try db.write { try $0.execute(sql: "DELETE FROM sync_queue") }
        let boardId = PullFixture.uuid(1, 0)
        XCTAssertEqual(try db.fetchBoard(id: boardId)?.version, 1)

        let later = Date(timeIntervalSince1970: 1_995_000_000)
        var board = fixture["boards"]![0]
        board["name"] = "Renamed elsewhere"
        board["version"] = 2
        board["completedTasks"] = 1
        board["updatedAt"] = "2026-07-02T12:00:01.000Z" // OLDER than any local clock stamp
        board["_syncedAt"] = later
        var event = fixture["taskEvents"]![0] // cell 0
        event["_syncedAt"] = later
        var task = fixture["tasks"]![0]
        task["version"] = 2
        task["isCompleted"] = true
        task["updatedAt"] = PullFixture.inWindow
        task["_syncedAt"] = later

        let source = FakePullSource(docsByCollection: ["boards": [board], "taskEvents": [event], "tasks": [task]])
        _ = await makeSut(db, source: source).pullSync(userId: userId, lastSyncedAt: nil)

        let after = try XCTUnwrap(try db.fetchBoard(id: boardId))
        XCTAssertEqual(after.name, "Renamed elsewhere", "the remote rename must survive")
        XCTAssertEqual(after.version, 2, "no locally authored bump")
        XCTAssertEqual(after.completedTasks, 1)
        XCTAssertEqual(try count(db, "sync_queue"), 0, "the pull must push nothing back")
    }

    // MARK: - boards.centerTaskId has no FK (v40)

    func test_v40_boardsHasNoCenterTaskForeignKey_andKeepsEveryIndex() throws {
        let db = try makeDb()
        try db.read { conn in
            let fks = try Row.fetchAll(conn, sql: "PRAGMA foreign_key_list(boards)")
            XCTAssertFalse(fks.contains { ($0["from"] as String?) == "centerTaskId" }, "centerTaskId must not reference tasks")
            XCTAssertTrue(fks.contains { ($0["table"] as String?) == "users" }, "the userId FK is kept")
            let indexes = try String.fetchAll(conn, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'boards' AND sql IS NOT NULL")
            XCTAssertEqual(Set(indexes), [
                "idx_boards_user_deleted", "idx_boards_user_timeframe_status",
                "idx_boards_user_timeframe_lines", "idx_boards_updated", "idx_boards_status",
            ])
            // board_tasks still cascades from boards.
            let btFks = try Row.fetchAll(conn, sql: "PRAGMA foreign_key_list(board_tasks)")
            XCTAssertTrue(btFks.contains { ($0["table"] as String?) == "boards" })
        }
    }

    /// Boards pull before tasks: a board whose chosen centre task arrives later
    /// in the same pull must not fail the boards batch (it used to, via the FK).
    func test_freshPull_boardWithCentreTaskArrivingLater_succeeds() async throws {
        let db = try makeDb()
        var fixture = PullFixture(boards: 1).docs
        let centreId = fixture["tasks"]![4]["id"] as! String // cell 4 = the centre of a 3×3
        fixture["boards"]![0]["centerSquareType"] = CenterSquareType.chosen.rawValue
        fixture["boards"]![0]["centerTaskId"] = centreId
        fixture["boardTasks"] = fixture["boardTasks"]!.map {
            var bt = $0
            if bt["taskId"] as? String == centreId { bt["isCenter"] = true }
            return bt
        }

        let result = await makeSut(db, source: FakePullSource(docsByCollection: fixture)).pullSync(userId: userId, lastSyncedAt: nil)

        XCTAssertFalse(result.details.contains { $0.contains("Pull failed") }, result.details.filter { $0.contains("failed") }.joined(separator: "\n"))
        let board = try XCTUnwrap(try db.fetchBoard(id: PullFixture.uuid(1, 0)))
        XCTAssertEqual(board.centerTaskId, centreId)
        XCTAssertNotNil(try db.fetchTask(id: centreId), "the centre task resolves once the tasks batch lands")
        XCTAssertNotNil(try db.fetchUser(id: userId)?.lastSyncedAt, "a clean pull — heals ran, lastSyncedAt stamped")
    }

    // MARK: - compoundChildren batch re-derives sealed boards

    /// A sealed board placing an AND compound: the compound is complete over
    /// its one local link. A newly pulled link to an incomplete sub-task makes
    /// it incomplete — the sealed snapshot must re-derive from that link.
    func test_pulledCompoundLink_reDerivesSealedBoardSnapshot() async throws {
        let db = try makeDb()
        let start = "2026-07-01T00:00:00.000Z"
        let (boardId, parentId, aId, bId) = (PullFixture.uuid(1, 77), PullFixture.uuid(2, 770), PullFixture.uuid(2, 771), PullFixture.uuid(2, 772))
        func task(_ id: String, _ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var t: [String: Any] = ["id": id, "userId": userId, "title": id, "type": type, "isCompleted": false,
                                    "totalCompletions": 0, "totalInstances": 0, "createdAt": start, "updatedAt": start,
                                    "version": 1, "isDeleted": false]
            for (k, v) in extra { t[k] = v }
            return t
        }
        func link(_ n: Int, _ child: String) -> [String: Any] {
            ["id": PullFixture.uuid(5, n), "compoundTaskId": parentId, "childTaskId": child, "childIndex": n,
             "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false]
        }
        let seed: [(String, [[String: Any]])] = [
            ("boards", [["id": boardId, "userId": userId, "name": "Sealed", "status": "active", "boardSize": 3,
                         "timeframe": Timeframe.daily.rawValue, "startDate": start, "endDate": "2026-07-05T23:59:59.999Z",
                         "sealedAt": "2026-07-06T00:00:00.000Z", "centerSquareType": CenterSquareType.none.rawValue,
                         "isRandomized": false, "totalTasks": 1, "completedTasks": 0, "linesCompleted": 0,
                         "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false]]),
            ("tasks", [task(parentId, "compound", ["operator": "AND"]), task(aId, "normal"), task(bId, "normal")]),
            ("compoundChildren", [link(0, aId)]),
            ("taskEvents", [["id": PullFixture.uuid(4, 770), "userId": userId, "taskId": aId, "kind": "completion",
                             "occurredAt": "2026-07-02T12:00:00.000Z", "createdAt": start, "updatedAt": start,
                             "version": 1, "isDeleted": false]]),
            ("boardTasks", [["id": PullFixture.uuid(3, 770), "boardId": boardId, "taskId": parentId, "row": 0, "col": 0,
                             "isCenter": false, "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false]]),
        ]
        for (name, docs) in seed {
            _ = try await db.applyPullBatch(collection: (name, syncableCollections.first { $0.firestoreName == name }!.grdbTable),
                                            docs: PullDocs(docs: docs), userId: userId, checkpoint: false)
        }
        XCTAssertEqual(try db.fetchBoard(id: boardId)?.completedTasks, 1, "precondition: AND over [A done] is complete")

        _ = try await db.applyPullBatch(collection: ("compoundChildren", "compound_children"),
                                        docs: PullDocs(docs: [link(1, bId)]), userId: userId, checkpoint: false)
        XCTAssertEqual(try db.fetchBoard(id: boardId)?.completedTasks, 0, "the sealed snapshot must re-derive from the new link")
    }

    // MARK: - lastSyncedAt = pull START (review I1)

    /// A remote write landing DURING a pull, in a collection without a
    /// checkpoint, must be picked up by the next pull (fallback = lastSyncedAt).
    func test_docWrittenDuringThePull_isPickedUpNextRound() async throws {
        let db = try makeDb()
        let lateTask = PullFixture(boards: 1).docs["tasks"]![0]
        let source = FakePullSource(docsByCollection: [:])
        source.onFetch = { collection in
            guard collection == "coreBoardDefaults" else { return }
            var doc = lateTask
            doc["_syncedAt"] = Date() // written while the pull is past `tasks`
            source.onFetch = nil
            source.add(doc, to: "tasks")
            // Push the end of the pull ≥ 1 s past the write, so an end-of-pull
            // stamp (floored to the second) would land after it.
            try? await _Concurrency.Task.sleep(nanoseconds: 1_100_000_000)
        }
        let sut = makeSut(db, source: source)
        _ = await sut.pullSync(userId: userId, lastSyncedAt: nil)
        XCTAssertNil(try db.fetchTask(id: lateTask["id"] as! String), "precondition: missed by round 1")
        XCTAssertNil(try watermarks(db)["tasks"], "precondition: tasks has no checkpoint")

        let stamp = try XCTUnwrap(try db.fetchUser(id: userId)?.lastSyncedAt)
        _ = await sut.pullSync(userId: userId, lastSyncedAt: stamp)
        XCTAssertNotNil(try db.fetchTask(id: lateTask["id"] as! String), "a mid-pull write was skipped forever")
    }

    // MARK: - (d) listeners attach only after the first pull

    func test_listenersAttachOnlyAfterTheFirstPullCompletes_fromTheFreshCheckpoints() async throws {
        let db = try makeDb()
        let fixture = PullFixture(boards: 2)
        let source = FakePullSource(docsByCollection: fixture.docs)
        let sut = makeSut(db, source: source)

        sut.start(userId: userId)
        defer { sut.stop() }
        try await waitUntil { source.events.filter { $0.hasPrefix("listen:") }.count == pullApplyOrder.count + 1 }

        let events = source.events
        let lastFetch = try XCTUnwrap(events.lastIndex { $0.hasPrefix("fetch:") })
        let firstListen = try XCTUnwrap(events.firstIndex { $0.hasPrefix("listen:") })
        XCTAssertLessThan(lastFetch, firstListen, "a listener attached before the first pull finished: \(events)")
        XCTAssertTrue(sut.hasCompletedFirstPull)
        XCTAssertEqual(source.listenSince["tasks"], fixture.maxSyncedAt("tasks"), "listener starts from the pull's checkpoint")

        // (5) Listener parity: a snapshot applies through the same engine and
        // never checkpoints (a change set is not a `_syncedAt` prefix).
        let before = try watermarks(db)
        var newTask = fixture.docs["tasks"]![0]
        newTask["id"] = PullFixture.uuid(2, 999)
        newTask["_syncedAt"] = Date(timeIntervalSince1970: 1_990_000_000)
        source.deliver([newTask], to: "tasks")
        try await waitUntil { (try? db.fetchTask(id: PullFixture.uuid(2, 999))) != nil }
        XCTAssertEqual(try watermarks(db), before)
    }

    /// Review I2: an offline / failing first pull still attaches the
    /// listeners, so real-time works once the connection returns.
    func test_listenersStillAttachWhenTheFirstPullFails() async throws {
        let db = try makeDb()
        let source = FakePullSource(docsByCollection: PullFixture(boards: 1).docs, failCollection: "tasks")
        let sut = makeSut(db, source: source)

        sut.start(userId: userId)
        defer { sut.stop() }
        try await waitUntil { source.events.filter { $0.hasPrefix("listen:") }.count == pullApplyOrder.count + 1 }
        XCTAssertTrue(sut.hasCompletedFirstPull)
        XCTAssertTrue(source.events.contains("fetch:tasks"), "the pull ran (and failed) first")
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - (e) main-thread budget

    /// CI variant: a synthetic account (120 boards → 1,080 tasks, 1,080
    /// placements, 360 events; ~10 batches). The structural property is the
    /// point — cascade lookups built at most once per batch — plus the
    /// main-thread stall bound.
    func test_fullPullOfSyntheticAccount_neverStallsTheMainThread() async throws {
        let db = try makeDb()
        let fixture = PullFixture(boards: 120)
        let sut = makeSut(db, source: FakePullSource(docsByCollection: fixture.docs))
        var batches = 0
        let lock = NSLock()
        AppDatabase.onPullBatchTransaction = { _ in lock.withLock { batches += 1 } }

        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        let started = Date()
        _ = await sut.pullSync(userId: userId, lastSyncedAt: nil)
        let elapsed = Date().timeIntervalSince(started)
        await heartbeat.stop()

        print("[pull-probe] synthetic: \(elapsed)s total, longest main stall \(heartbeat.maxGap)s, \(batches) batches, \(AppDatabase.pullCascadeLookupLoads) lookup loads")
        XCTAssertLessThanOrEqual(AppDatabase.pullCascadeLookupLoads, lock.withLock { batches })
        XCTAssertLessThan(heartbeat.maxGap, 1.0, "the main thread stalled for \(heartbeat.maxGap)s")
        try assertEveryBoardDerived(db, fixture)
    }

    /// Owner replay: applies a real Firestore dump (kept OUTSIDE the repo —
    /// private data). Set `OYBC_OWNER_DUMP` to its absolute path (from
    /// xcodebuild: `TEST_RUNNER_OYBC_OWNER_DUMP=/path`). Also times the
    /// pre-fix shape — one synchronous write + cascade per doc on the main
    /// thread, via the 1-doc seam — on a second fresh DB, for the PR numbers.
    func test_ownerDumpReplay_mainThreadStallUnderOneSecond() async throws {
        guard let path = ProcessInfo.processInfo.environment["OYBC_OWNER_DUMP"] else {
            throw XCTSkip("OYBC_OWNER_DUMP not set")
        }
        let (uid, docs, userDoc) = try loadDump(path)
        let total = docs.values.map(\.count).reduce(0, +)

        let db = try AppDatabase.makeTestInstance()
        let sut = SyncService(database: db, currentAuthUid: { uid }, docStore: NullDocStore(), pullSource: FakePullSource(docsByCollection: docs, userDoc: userDoc))
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        let started = Date()
        let result = await sut.pullSync(userId: uid, lastSyncedAt: nil)
        let elapsed = Date().timeIntervalSince(started)
        await heartbeat.stop()
        let newLoads = AppDatabase.pullCascadeLookupLoads
        XCTAssertFalse(result.details.contains { $0.contains("Pull failed") }, result.details.filter { $0.contains("failed") }.joined(separator: "\n"))

        // Pre-fix shape, for comparison: per-doc writes on the main thread.
        let legacyDb = try AppDatabase.makeTestInstance()
        if let userDoc { _ = try legacyDb.write { try AppDatabase.applyPulledUserDocTx(db: $0, userId: uid, remoteData: userDoc) } }
        let legacy = SyncService(database: legacyDb, currentAuthUid: { uid }, docStore: NullDocStore(), pullSource: FakePullSource(docsByCollection: [:]))
        let legacyStarted = Date()
        let legacyOrder = ["boards", "tasks", "boardTasks", "compoundChildren", "recurringBoardTemplates", "pools", "coreBoardDefaults"]
        for name in legacyOrder {
            let col = syncableCollections.first { $0.firestoreName == name }!
            for doc in docs[name] ?? [] { legacy.applyRemoteSubdoc(collection: col, remoteData: doc, authenticatedUserId: uid) }
        }
        legacy.applyTaskEventsBatch(userId: uid, rawDocs: docs["taskEvents"] ?? [])
        let legacyElapsed = Date().timeIntervalSince(legacyStarted)

        print("[pull-probe] owner dump: \(total) docs, legacy per-doc lookup loads \(AppDatabase.pullCascadeLookupLoads - newLoads). NEW: \(elapsed)s total, longest main stall \(heartbeat.maxGap)s, \(newLoads) lookup loads. PER-DOC ON MAIN (pre-fix shape): \(legacyElapsed)s, all of it on the main thread")
        XCTAssertLessThan(heartbeat.maxGap, 1.0, "the main thread stalled for \(heartbeat.maxGap)s")
    }

    /// Reads `{ uid: { user, tasks: [...], … } }`, picks the account with the
    /// most tasks, turns each ISO `_syncedAt` into a `Date` and drops the
    /// dump-only `_id` / `_updateTime` keys.
    private func loadDump(_ path: String) throws -> (String, [String: [[String: Any]]], [String: Any]?) {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: [String: Any]])
        let (uid, account) = try XCTUnwrap(root.max { ($0.value["tasks"] as? [Any])?.count ?? 0 < ($1.value["tasks"] as? [Any])?.count ?? 0 })
        func clean(_ doc: [String: Any]) -> [String: Any] {
            var out = doc
            out.removeValue(forKey: "_id")
            out.removeValue(forKey: "_updateTime")
            out["_syncedAt"] = (doc["_syncedAt"] as? String).flatMap(DateFormatting.parseISO)
            return out
        }
        var docs: [String: [[String: Any]]] = [:]
        for name in pullApplyOrder {
            docs[name] = ((account[name] as? [[String: Any]]) ?? []).map(clean)
        }
        return (uid, docs, (account["user"] as? [String: Any]).map(clean))
    }
}
