import XCTest
import GRDB
@testable import OYBC

/// Counter kinds — the root kind switch + family cascade
/// (docs/COUNTER_KINDS.md D4/D5, Review Focus #2 / #3). Web twin:
/// `countKindSwitch.test.ts`. A root, an in-window derived row (live) and an
/// ended derived row (frozen), each placed on its own board.
@MainActor
final class AppDatabaseCountKindSwitchTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let now = DateFormatting.parseISO("2026-09-23T12:00:00.000Z")!
    private let liveStart = "2026-09-21T00:00:00.000Z", liveEnd = "2026-09-27T23:59:59.999Z"
    private let endedStart = "2026-09-14T00:00:00.000Z", endedEnd = "2026-09-20T23:59:59.999Z"

    private func seedFamily(
        kind: CountKind, rootGoal: CountValue, liveTarget: CountValue = 6,
        endedTarget: CountValue = 6, deltas: [CountValue] = []
    ) throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var root = K.task("root", maxCount: rootGoal, currentCount: deltas.reduce(0, +))
        root.countKind = kind
        root.defaultLogAmount = 1
        try db.saveTask(root)
        var live = K.task("live", maxCount: liveTarget, sharedCounterId: "root",
                          startDate: liveStart, endDate: liveEnd, createdInWizard: true, baseline: 0)
        live.countKind = kind
        try db.saveTask(live)
        var ended = K.task("ended", maxCount: endedTarget, sharedCounterId: "root",
                           startDate: endedStart, endDate: endedEnd, createdInWizard: true, baseline: 0)
        ended.countKind = kind
        try db.saveTask(ended)
        try db.saveBoard(K.board(id: "bLive", startDate: liveStart, endDate: liveEnd, timeframe: .weekly))
        try db.saveBoard(K.board(id: "bEnded", startDate: endedStart, endDate: endedEnd, timeframe: .weekly))
        try db.saveBoardTask(K.placement(id: "btLive", boardId: "bLive", taskId: "live"))
        try db.saveBoardTask(K.placement(id: "btEnded", boardId: "bEnded", taskId: "ended"))
        for (i, delta) in deltas.enumerated() {
            try K.addIncrement(db, taskId: "root", delta: delta, occurredAt: "2026-09-22T0\(i):00:00.000Z")
        }
        return db
    }

    private func allEvents(_ db: AppDatabase) throws -> [TaskEvent] {
        try db.read { try TaskEvent.order(Column("id")).fetchAll($0) }
    }

    /// Byte-stable snapshot of every event row (TaskEvent is not Equatable).
    private func eventSnapshot(_ db: AppDatabase) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(allEvents(db))
    }

    /// What the live row's cell shows: the root's in-window sum, finalised by the row's kind.
    private func displayedLive(_ db: AppDatabase) throws -> CountValue {
        let row = try XCTUnwrap(K.fetchTask(db, "live"))
        let board = try XCTUnwrap(db.fetchBoard(id: "bLive"))
        let byTask = Dictionary(grouping: try allEvents(db).filter { !$0.isDeleted }, by: \.taskId)
        return resolveLinkedCounterDisplay(
            task: row, eventsByTaskId: byTask, sealedAt: nil, window: LinkedCounterWindow(board: board)
        ).displayed
    }

    private func taskQueueIds(_ db: AppDatabase) throws -> [String] {
        try db.fetchPendingSyncItems().filter { $0.entityType == "tasks" }.map(\.entityId).sorted()
    }

    func test_continuousToDiscrete_roundsRootAndLiveFamily_frozenRowAndEventsUntouched() throws {
        let db = try seedFamily(kind: .continuous, rootGoal: 26.2, liveTarget: 6.1, endedTarget: 6.4,
                                deltas: [0.4, 0.4, 0.4])
        let eventsBefore = try eventSnapshot(db)
        let endedBefore = try XCTUnwrap(K.fetchTask(db, "ended"))

        try db.switchCounterKind(rootTaskId: "root", to: .discrete, now: now)

        let root = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(root.countKind, .discrete)
        XCTAssertEqual(root.maxCount, 26)
        XCTAssertEqual(root.defaultLogAmount, 1)
        XCTAssertEqual(root.version, 2)
        let live = try XCTUnwrap(K.fetchTask(db, "live"))
        XCTAssertEqual(live.countKind, .discrete)
        XCTAssertEqual(live.maxCount, 6)
        XCTAssertEqual(live.version, 2)
        let ended = try XCTUnwrap(K.fetchTask(db, "ended"))
        XCTAssertEqual(ended.countKind, .continuous)
        XCTAssertEqual(ended.maxCount, 6.4)
        XCTAssertEqual(ended.version, endedBefore.version)
        XCTAssertEqual(ended.updatedAt, endedBefore.updatedAt)
        XCTAssertEqual(try eventSnapshot(db), eventsBefore)
    }

    func test_roundTrip_restoresExactWindowCount() throws {
        let db = try seedFamily(kind: .continuous, rootGoal: 26.2, liveTarget: 6.1, deltas: [0.4, 0.4, 0.4])
        XCTAssertEqual(try displayedLive(db), 1.2)

        try db.switchCounterKind(rootTaskId: "root", to: .discrete, now: now)
        XCTAssertEqual(try displayedLive(db), 1)

        try db.switchCounterKind(rootTaskId: "root", to: .continuous, now: now)
        XCTAssertEqual(try displayedLive(db), 1.2)
        // The goals rounded on the way down stay whole on the way back up.
        XCTAssertEqual(try K.fetchTask(db, "root")?.maxCount, 26)
        XCTAssertEqual(try K.fetchTask(db, "live")?.countKind, .continuous)
    }

    func test_restampsLifetimeCaches_atTheGoalLine_bothDirections() throws {
        let db = try seedFamily(kind: .continuous, rootGoal: 26.2, liveTarget: 6.1, deltas: [25.6])

        try db.switchCounterKind(rootTaskId: "root", to: .discrete, now: now)
        var root = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(root.maxCount, 26)
        XCTAssertTrue(root.isCompleted)
        XCTAssertEqual(root.currentCount, 26)

        try db.switchCounterKind(rootTaskId: "root", to: .continuous, now: now)
        root = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(root.maxCount, 26)
        XCTAssertFalse(root.isCompleted)
        XCTAssertEqual(root.currentCount, 25.6)
    }

    func test_refusesDurationNoOpLinkedRowsAndNonCounters_writingNothing() throws {
        let db = try seedFamily(kind: .discrete, rootGoal: 30)
        var normal = K.task("normal", maxCount: nil)
        normal.type = .normal
        try db.saveTask(normal)
        var duration = K.task("durRoot", maxCount: 30)
        duration.countKind = .duration
        try db.saveTask(duration)

        XCTAssertThrowsError(try db.switchCounterKind(rootTaskId: "root", to: .duration, now: now)) {
            XCTAssertEqual($0 as? CountKindSwitchError, .refused)
        }
        XCTAssertThrowsError(try db.switchCounterKind(rootTaskId: "durRoot", to: .discrete, now: now)) {
            XCTAssertEqual($0 as? CountKindSwitchError, .refused)
        }
        XCTAssertThrowsError(try db.switchCounterKind(rootTaskId: "root", to: .discrete, now: now)) {
            XCTAssertEqual($0 as? CountKindSwitchError, .refused)
        }
        XCTAssertThrowsError(try db.switchCounterKind(rootTaskId: "live", to: .continuous, now: now)) {
            XCTAssertEqual($0 as? CountKindSwitchError, .notARoot)
        }
        XCTAssertThrowsError(try db.switchCounterKind(rootTaskId: "normal", to: .continuous, now: now)) {
            XCTAssertEqual($0 as? CountKindSwitchError, .notCounting)
        }
        XCTAssertThrowsError(try db.switchCounterKind(rootTaskId: "missing", to: .continuous, now: now)) {
            XCTAssertEqual($0 as? CountKindSwitchError, .notCounting)
        }

        let root = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(root.countKind, .discrete)
        XCTAssertEqual(root.maxCount, 30)
        XCTAssertEqual(root.version, 1)
        XCTAssertEqual(try K.fetchTask(db, "durRoot")?.countKind, .duration)
        XCTAssertEqual(try taskQueueIds(db), [])
    }

    func test_enqueuesOneUpdatePerWrittenRow_andWritesDiscreteExplicitly() throws {
        let db = try seedFamily(kind: .discrete, rootGoal: 30, liveTarget: 5)
        var preFeature = try XCTUnwrap(K.fetchTask(db, "root"))
        preFeature.countKind = nil // absent ⇒ discrete
        try db.saveTask(preFeature)

        try db.switchCounterKind(rootTaskId: "root", to: .continuous, now: now)
        try db.switchCounterKind(rootTaskId: "root", to: .discrete, now: now)

        let taskItems = try db.fetchPendingSyncItems().filter { $0.entityType == "tasks" }
        // Two switches, one PENDING row per entity: the queue coalesces
        // (SyncQueueBuilder), same shape as web's `[ROOT, LIVE]`.
        XCTAssertEqual(taskItems.map(\.entityId).sorted(), ["live", "root"])
        XCTAssertEqual(taskItems.count, 2)
        let root = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(root.countKind, .discrete)
        XCTAssertEqual(root.version, 3)
        let rootPayloads = try taskItems.filter { $0.entityId == "root" }
            .map { try JSONDecoder().decode(Task.self, from: Data($0.payload.utf8)) }
        XCTAssertEqual(rootPayloads.count, 1)
        let latest = try XCTUnwrap(rootPayloads.first)
        XCTAssertEqual(latest.countKind, .discrete)
        XCTAssertEqual(latest.version, 3)
    }

    func test_newLinkedRowToContinuousRoot_isContinuous() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var root = K.task("root", maxCount: 26.2, currentCount: 1.2)
        root.countKind = .continuous
        try db.saveTask(root)

        // The "Derive smaller version" / quick-add path: a VM-built linked row
        // with no kind of its own.
        let linked = K.task("linked", maxCount: 5, sharedCounterId: "root", baseline: 1.2)
        XCTAssertNil(linked.countKind)
        try db.createTaskAndEnqueue(linked, now: "2026-09-23T12:00:00.000Z")

        XCTAssertEqual(try K.fetchTask(db, "linked")?.countKind, .continuous)
    }
}
