import XCTest
import GRDB
@testable import OYBC

/// Board Sources §Member rules B2 (iOS) — the *Deletion* half plus the three
/// readers that ride with it. Swift twin of
/// `apps/web/src/db/operations/__tests__/derivedCountersCascade.test.ts` (and
/// the `counterOps` / `repeatBoard` / `templateHealth` / `taskCountDisplay`
/// additions from the same web commit).
///
/// A window-stamped derived counter is a per-window artifact of the board it
/// was minted for: it is not library content the user authored, so when its
/// root is deleted (or the last board carrying it goes away) it must be
/// retired outright rather than unlinked and left behind as a mystery row.
/// These tests pin the write rulings the pure algorithms cannot express: every
/// tombstone bumps `version` AND enqueues its own sync item (a soft-delete
/// helper that forgets the enqueue resurrects the row on the next pull), the
/// placements/links go with the task, and RB5's "live placement" definition (a
/// live `board_tasks` row on a live board) decides whether a derived row
/// survives its board's deletion.
final class DerivedCountersCascadeTests: XCTestCase {

    // MARK: - Fixtures

    private let userId = "u1"
    private let root = "root-counter-1"
    private let now = "2026-09-18T10:00:00.000Z"
    private let windowStart = "2026-09-14T00:00:00.000Z"
    private let windowEnd = "2026-09-20T23:59:59.999Z"
    private let earlier = "2026-09-14T08:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let database = try AppDatabase.makeTestInstance()
        try database.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: earlier, updatedAt: earlier, lastSyncedAt: nil, version: 1
        ))
        return database
    }

    /// A stored row with all three `isWindowStampedDerived` marks.
    private func derivedCounter(
        id: String,
        rootId: String? = nil,
        startDate: String? = nil,
        createdInWizard: Bool = true,
        currentCount: CountValue = 0,
        isCompleted: Bool = false,
        version: Int = 1,
        isDeleted: Bool = false
    ) -> Task {
        Task(
            id: id, userId: userId, title: "Run 5 km", type: .counting,
            action: "Run", unit: "km", maxCount: 5,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, currentCount: currentCount,
            createdAt: earlier, updatedAt: earlier, version: version,
            isDeleted: isDeleted, deletedAt: isDeleted ? earlier : nil,
            timeframe: .weekly, startDate: startDate ?? windowStart, endDate: windowEnd,
            sharedCounterId: rootId ?? root, baseline: 0,
            createdInWizard: createdInWizard
        )
    }

    /// A per-window derived COMPOUND (no `sharedCounterId`; the other two marks).
    private func derivedCompound(
        id: String,
        startDate: String? = nil,
        createdInWizard: Bool = true
    ) -> Task {
        Task(
            id: id, userId: userId, title: "Strength circuit", type: .compound,
            operatorType: .and,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false,
            createdAt: earlier, updatedAt: earlier, version: 1, isDeleted: false,
            timeframe: .weekly, startDate: startDate ?? windowStart, endDate: windowEnd,
            createdInWizard: createdInWizard
        )
    }

    private func plainTask(id: String, type: TaskType = .normal) -> Task {
        Task(
            id: id, userId: userId, title: "Plain", type: type,
            operatorType: type == .compound ? .and : nil,
            totalCompletions: 0, totalInstances: 0, isCompleted: false,
            createdAt: earlier, updatedAt: earlier, version: 1, isDeleted: false
        )
    }

    private func makeBoard(
        id: String,
        isDeleted: Bool = false,
        startDate: String? = nil,
        timeframe: Timeframe = .weekly
    ) throws -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Week board",
            "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": timeframe.rawValue,
            "startDate": startDate ?? windowStart, "endDate": windowEnd,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": earlier, "updatedAt": earlier, "version": 1,
            "isDeleted": isDeleted,
        ]
        if isDeleted { dict["deletedAt"] = earlier }
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private var nextCell = 0

    private func placement(
        id: String,
        boardId: String,
        taskId: String,
        isDeleted: Bool = false,
        version: Int = 1
    ) -> BoardTask {
        nextCell += 1
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId,
            row: nextCell / 3, col: nextCell % 3, isCenter: false,
            createdAt: earlier, updatedAt: earlier, version: version,
            isDeleted: isDeleted, deletedAt: isDeleted ? earlier : nil
        )
    }

    private func link(id: String, compoundTaskId: String, childTaskId: String, index: Int = 0) -> CompoundChild {
        CompoundChild(
            id: id, compoundTaskId: compoundTaskId, childTaskId: childTaskId,
            childIndex: index, createdAt: earlier, updatedAt: earlier,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func queue(_ database: AppDatabase, _ entityType: String, _ entityId: String) throws -> [SyncQueueItem] {
        try database.read { db in
            try SyncQueueItem
                .filter(Column("entityType") == entityType && Column("entityId") == entityId)
                .fetchAll(db)
        }
    }

    private func task(_ database: AppDatabase, _ id: String) throws -> Task? {
        try database.read { try Task.fetchOne($0, key: id) }
    }

    private func boardTask(_ database: AppDatabase, _ id: String) throws -> BoardTask? {
        try database.read { try BoardTask.fetchOne($0, key: id) }
    }

    private func childLink(_ database: AppDatabase, _ id: String) throws -> CompoundChild? {
        try database.read { try CompoundChild.fetchOne($0, key: id) }
    }





    // MARK: - (d) repeatBoardAsTemplate — RB4

    /// Slice 3b (ruling 1): Repeat copies a placement's frozen override / title
    /// into the record's `manualTaskTargets`, keyed by the member id.
    func test_repeatBoard_collectsManualTaskTargetsFromPlacementOverrides() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "board-r4")
        try database.write { db in
            try board.insert(db)
            try self.plainTask(id: self.root, type: .counting).insert(db)
            try self.plainTask(id: "plain-r4").insert(db)
            try BoardTask(
                id: "bt-r4a", boardId: board.id, taskId: self.root, row: 0, col: 0, isCenter: false,
                targetOverride: 7, targetKind: .discrete, titleOverride: "Seven",
                createdAt: self.earlier, updatedAt: self.earlier, version: 1
            ).insert(db)
            try self.placement(id: "bt-r4b", boardId: board.id, taskId: "plain-r4").insert(db)
        }

        let template = try XCTUnwrap(try database.repeatBoardAsTemplate(
            board: board, cadence: .weekly, userId: userId, weekStartDay: "monday", now: now
        ))

        XCTAssertEqual(template.manualTaskTargets, [root: ManualTaskTarget(target: 7, kind: .discrete, title: "Seven")])
        let stored = try XCTUnwrap(try database.fetchRecurringBoardTemplate(id: template.id))
        XCTAssertEqual(stored.manualTaskTargets?[root]?.target, 7)
    }

    // MARK: - Deletion (slice 5: every linked member is a counter member)

    func test_computeTaskDeletionImpact_countsEveryLiveLinkedMember() throws {
        let database = try makeDb()
        try database.write { db in
            try self.plainTask(id: self.root, type: .counting).insert(db)
            try self.derivedCounter(id: "ordinary-b", createdInWizard: false).insert(db)
            try self.derivedCounter(id: "marked-b").insert(db)
        }

        let impact = try database.computeTaskDeletionImpact(taskId: root)

        XCTAssertEqual(impact.counterMemberCount, 2)
        XCTAssertEqual(impact.counterMembers.map { $0.id }.sorted(), ["marked-b", "ordinary-b"])
    }

    func test_computeTaskDeletionImpact_reportsNoMembersForAPlainTask() throws {
        let database = try makeDb()
        try database.write { db in try self.plainTask(id: "solo").insert(db) }

        XCTAssertEqual(try database.computeTaskDeletionImpact(taskId: "solo").counterMemberCount, 0)
    }

    func test_deleteCounterWithUnlink_unlinksEveryMember_seedingFromTheRootsLifetimeEvents() throws {
        let database = try makeDb()
        var source = plainTask(id: root, type: .counting)
        source.maxCount = 100
        source.isCounter = true
        var ordinary = derivedCounter(id: "ordinary-c", createdInWizard: false)
        ordinary.baseline = 10 // never read
        let marked = derivedCounter(id: "marked-c")
        try database.write { db in
            try source.insert(db)
            try ordinary.insert(db)
            try marked.insert(db)
            try TaskEvent(
                id: "ev-root", userId: self.userId, taskId: self.root, kind: .increment, delta: 30,
                occurredAt: self.earlier, boardId: nil, createdAt: self.earlier, updatedAt: self.earlier,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).insert(db)
        }

        try database.deleteCounterWithUnlink(sourceId: root, now: now)

        for id in ["ordinary-c", "marked-c"] {
            let unlinked = try XCTUnwrap(try task(database, id))
            XCTAssertFalse(unlinked.isDeleted, id)
            XCTAssertNil(unlinked.sharedCounterId, id)
            XCTAssertEqual(unlinked.currentCount, 30, "\(id): the root's lifetime event sum, baseline unread")
        }
    }

    // MARK: - (e) roster health — Split-up expansion

    func test_rosterHealth_aSplitUpMemberRuleExpandsTheCompoundBeforeTheCount() throws {
        // The roster count must be the honest one: a compound member the user
        // set to "Split up" contributes its parts, so a 7-member supply with a
        // 3-part compound is 9 squares, not 7 — the same expansion a new
        // window's assembly performs.
        let plainIds = (1...6).map { "plain-\($0)" }
        let partIds = ["part-1", "part-2", "part-3"]
        var tasksById: [String: Task] = [:]
        for id in plainIds + partIds { tasksById[id] = plainTask(id: id) }
        tasksById["c1"] = plainTask(id: "c1", type: .compound)

        let source = BoardSource(
            sourceId: "p1", kind: .pool, min: 0, max: nil,
            excludedTaskIds: [], filter: .all,
            memberRules: ["c1": BoardSourceMemberRule(split: true)]
        )
        let template = RecurringBoardTemplate(
            id: "tpl-1", userId: userId, name: "Weekly", timeframe: .weekly,
            boardSize: 3, centerSquareType: .none, isRandomized: false,
            seedTaskIds: [], poolIds: [], manualTaskIds: [], removedTaskIds: [],
            sources: [source], manualTaskVary: [:],
            isActive: true, createdAt: now, updatedAt: now, version: 1
        )
        let links = partIds.enumerated().map { index, childId in
            link(id: "l-\(index)", compoundTaskId: "c1", childTaskId: childId, index: index)
        }
        let resolution = RecurringBoardTemplatesViewModel.TemplateSupplyResolution(
            supplies: [BoardSources.Supply(source: source, supplyTaskIds: ["c1"] + plainIds)],
            deadBoardSourceIds: [],
            manualTaskIds: [],
            childrenByCompoundId: ["c1": links]
        )

        let health = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [template],
            resolutionByTemplateId: ["tpl-1": resolution],
            tasksById: tasksById
        )

        let mix = try XCTUnwrap(health.mixByTemplateId["tpl-1"])
        XCTAssertFalse(mix.contains("c1"), "the split member itself never reaches the board")
        for partId in partIds { XCTAssertTrue(mix.contains(partId), "\(partId) must be in the mix") }
        XCTAssertEqual(mix.count, 9, "3 parts + 6 plain members = a full 3x3")
        XCTAssertNil(health.attentionByTemplateId["tpl-1"])
    }

    func test_rosterHealth_withoutASplitRuleTheCompoundCountsAsOneSquare() throws {
        // The non-degenerate control for the test above: same supply, no rule.
        let plainIds = (1...6).map { "plain-\($0)" }
        var tasksById: [String: Task] = [:]
        for id in plainIds + ["part-1", "part-2", "part-3"] { tasksById[id] = plainTask(id: id) }
        tasksById["c1"] = plainTask(id: "c1", type: .compound)

        let source = BoardSource(
            sourceId: "p1", kind: .pool, min: 0, max: nil,
            excludedTaskIds: [], filter: .all, memberRules: [:]
        )
        let template = RecurringBoardTemplate(
            id: "tpl-2", userId: userId, name: "Weekly", timeframe: .weekly,
            boardSize: 3, centerSquareType: .none, isRandomized: false,
            seedTaskIds: [], poolIds: [], manualTaskIds: [], removedTaskIds: [],
            sources: [source], manualTaskVary: [:],
            isActive: true, createdAt: now, updatedAt: now, version: 1
        )
        let links = ["part-1", "part-2", "part-3"].enumerated().map { index, childId in
            link(id: "l2-\(index)", compoundTaskId: "c1", childTaskId: childId, index: index)
        }
        let resolution = RecurringBoardTemplatesViewModel.TemplateSupplyResolution(
            supplies: [BoardSources.Supply(source: source, supplyTaskIds: ["c1"] + plainIds)],
            deadBoardSourceIds: [],
            manualTaskIds: [],
            childrenByCompoundId: ["c1": links]
        )

        let health = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [template],
            resolutionByTemplateId: ["tpl-2": resolution],
            tasksById: tasksById
        )

        let mix = try XCTUnwrap(health.mixByTemplateId["tpl-2"])
        XCTAssertTrue(mix.contains("c1"))
        XCTAssertEqual(mix.count, 7, "the compound is ONE square without a Split-up rule")
        XCTAssertEqual(health.attentionByTemplateId["tpl-2"], .poolTooSmall,
                       "7 squares cannot fill a 3x3 — the honest badge")
    }

    // MARK: - (f) read audit — RB7

    private func countingTask(
        id: String,
        sharedCounterId: String? = nil,
        baseline: CountValue? = nil,
        maxCount: CountValue?,
        currentCount: CountValue,
        isCompleted: Bool = false
    ) -> Task {
        Task(
            id: id, userId: userId, title: "Run", type: .counting,
            action: "Run", unit: "km", maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, currentCount: currentCount,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId, baseline: baseline
        )
    }

    /// Live increment events for `rootId` (one per delta), keyed for the
    /// context-less readers.
    private func increments(_ rootId: String, _ deltas: [CountValue]) -> [String: [TaskEvent]] {
        [rootId: deltas.enumerated().map { i, d in
            TaskEvent(
                id: "ev-\(rootId)-\(i)", userId: userId, taskId: rootId,
                kind: .increment, delta: d, occurredAt: earlier, boardId: nil,
                createdAt: earlier, updatedAt: earlier,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            )
        }]
    }

    // Slice 2c: the count is the root's lifetime EVENT sum — `baseline` and the
    // `currentCount` mirror are no longer read by any library reader.
    func test_displayedCount_linkedMemberReadsTheRootsLifetimeEvents() {
        let linked = countingTask(id: "linked", sharedCounterId: "root-1",
                                  baseline: 10, maxCount: 5, currentCount: 12)
        let events = increments("root-1", [10, 2])
        XCTAssertEqual(TaskCountDisplay.displayedCount(for: linked, eventsByTaskId: events), 12,
                       "re-pinned: lifetime events, no baseline subtraction")

        let rootTask = countingTask(id: "root-1", maxCount: 20, currentCount: 99)
        XCTAssertEqual(TaskCountDisplay.displayedCount(for: rootTask, eventsByTaskId: events), 12,
                       "re-pinned: the root's own events, not the currentCount mirror")
    }

    func test_displayedCount_noEventsIsZeroAndOvershootIsNeverClamped() {
        let none = countingTask(id: "under", sharedCounterId: "r", baseline: 20,
                                maxCount: 5, currentCount: 5)
        XCTAssertEqual(TaskCountDisplay.displayedCount(for: none, eventsByTaskId: nil), 0)

        let over = countingTask(id: "over", sharedCounterId: "r", baseline: 0,
                                maxCount: 5, currentCount: 0)
        XCTAssertEqual(TaskCountDisplay.displayedCount(for: over, eventsByTaskId: increments("r", [9])), 9,
                       "overshoot past the goal is real progress — never clamped")
    }

    func test_isInProgress_readsTheRootsLifetimeEvents() {
        let library = TaskLibraryViewModel()
        library.eventsByTaskId = increments("root-1", [3])
        // Re-pinned: a member of a root with events is in progress (lifetime
        // reading, baseline no longer subtracted); a member of an untouched
        // root is not.
        let started = countingTask(id: "started", sharedCounterId: "root-1",
                                   baseline: 12, maxCount: 5, currentCount: 12)
        XCTAssertTrue(TasksTabViewModel.isInProgress(started, library: library))

        let fresh = countingTask(id: "fresh", sharedCounterId: "root-2",
                                 baseline: 0, maxCount: 5, currentCount: 12)
        XCTAssertFalse(TasksTabViewModel.isInProgress(fresh, library: library))

        // Reaching the goal is done, not in progress — read from events, not the latch.
        library.eventsByTaskId = increments("root-1", [5])
        XCTAssertFalse(TasksTabViewModel.isInProgress(started, library: library))
        XCTAssertTrue(TasksTabViewModel.isDone(started, library: library))
    }

    /// A compound's "In progress" reads a COUNTING child's event state, never
    /// its (stale) `isCompleted` latch.
    func test_isInProgress_compoundReadsCountingChildFromEvents() {
        let library = TaskLibraryViewModel()
        let compound = Task(
            id: "cmp", userId: userId, title: "Routine", type: .compound, operatorType: .and,
            totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        let stale = countingTask(id: "kid", sharedCounterId: "root-1", maxCount: 5, currentCount: 5, isCompleted: true)
        library.libraryTasks = [compound, stale]
        library.compoundChildrenByCompound = ["cmp": [CompoundChild(
            id: "l1", compoundTaskId: "cmp", childTaskId: "kid", childIndex: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )]]

        library.eventsByTaskId = [:]
        XCTAssertFalse(TasksTabViewModel.isInProgress(compound, library: library),
                       "a stale latch with no events is not progress")

        library.eventsByTaskId = increments("root-1", [5])
        XCTAssertTrue(TasksTabViewModel.isInProgress(compound, library: library),
                      "a child that reached its goal in events is progress")

        // A non-counting child still reads its cache.
        var normalKid = Task(
            id: "nk", userId: userId, title: "n", type: .normal,
            totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        normalKid.isCompleted = true
        library.libraryTasks = [compound, normalKid]
        library.compoundChildrenByCompound = ["cmp": [CompoundChild(
            id: "l2", compoundTaskId: "cmp", childTaskId: "nk", childIndex: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )]]
        XCTAssertTrue(TasksTabViewModel.isInProgress(compound, library: library))
    }

    // MARK: - (h) read audit — the displayed count (final-review item 9)

    func test_displayedCount_readsTheRootsEventsNotTheMirror() {
        let linked = countingTask(id: "linked-h", sharedCounterId: "root-1",
                                  baseline: 10, maxCount: 5, currentCount: 12)
        XCTAssertEqual(TaskCountDisplay.displayedCount(for: linked, eventsByTaskId: increments("root-1", [4])), 4)
    }
}
