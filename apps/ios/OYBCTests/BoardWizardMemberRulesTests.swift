import GRDB
import XCTest
@testable import OYBC

/// Board Sources §Member rules (B3, docs/BOARD_SOURCES.md) — the wizard's
/// rule-editing layer (`BoardWizardViewModel+MemberRules.swift`), the
/// Split-up-aware supply expansion it feeds (`+Sources.swift`), and the
/// RC4/RC5 supply info the one-off "remaining" prefill reads
/// (`AppDatabase+BoardSources.swift`).
///
/// Swift twin of web's `wizardMemberRulesLogic` suite. Everything here runs
/// against an isolated `AppDatabase.makeTestInstance()` — the VM resolves
/// board supplies + compound links synchronously through its injected
/// database, so a pull is a real read of real rows.
final class BoardWizardMemberRulesTests: XCTestCase {

    /// An ENDED board is never a source (owner ruling 2026-09-24), judged
    /// against the wall clock by default. These fixtures live on fixed dates,
    /// so the source clock is pinned inside the 2026-09-18 source boards' window.
    override func setUp() {
        super.setUp()
        AppDatabase.sourceClock = { parseISO8601Date("2026-09-18T09:00:00.000Z")! }
    }

    override func tearDown() {
        AppDatabase.sourceClock = { Date() }
        super.tearDown()
    }

    // MARK: - Fixtures

    private let userId = "u1"
    private let now = "2026-09-18T09:00:00.000Z"
    private let sourceBoardId = "source-board"
    private let windowStart = "2026-09-18T00:00:00.000Z"
    private let windowEnd = "2026-09-18T23:59:59.999Z"

    private func makeDb() throws -> AppDatabase {
        let database = try AppDatabase.makeTestInstance()
        try database.write { db in
            try User(
                id: self.userId, email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil, version: 1
            ).save(db)
        }
        return database
    }

    private func makeTask(
        _ id: String,
        type: TaskType = .normal,
        maxCount: Int? = nil
    ) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: userId, title: "Task \(id)", type: type,
            action: type == .counting ? "Read" : nil,
            unit: type == .counting ? "pages" : nil,
            maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
    }

    private func makeEvent(
        _ id: String, taskId: String, delta: Int, at occurredAt: String, isDeleted: Bool = false
    ) -> TaskEvent {
        TaskEvent(
            id: id, userId: userId, taskId: taskId, kind: .increment, delta: delta,
            occurredAt: occurredAt, boardId: nil,
            createdAt: occurredAt, updatedAt: occurredAt, lastSyncedAt: nil,
            version: 1, isDeleted: isDeleted, deletedAt: isDeleted ? occurredAt : nil
        )
    }

    private func makeBoard(
        id: String,
        timeframe: Timeframe = .daily,
        startDate: String? = nil,
        endDate: String? = nil
    ) throws -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Source", "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": timeframe.rawValue,
            "startDate": startDate ?? windowStart, "endDate": endDate ?? windowEnd,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ]
        return try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
    }

    /// Seeds the canonical source board: a compound `C` with three children
    /// (`c1`/`c2`/`c3`), a counting member `cnt` (goal 10, 3 logged inside
    /// the board's window and 5 before it), and a normal member `n1`.
    @discardableResult
    private func seedSourceBoard(_ database: AppDatabase) throws -> AppDatabase {
        let board = try makeBoard(id: sourceBoardId)
        try database.write { db in
            try board.save(db)
            try self.makeTask("C", type: .compound).save(db)
            for child in ["c1", "c2", "c3"] { try self.makeTask(child).save(db) }
            try self.makeTask("cnt", type: .counting, maxCount: 10).save(db)
            try self.makeTask("n1").save(db)
            for (index, child) in ["c1", "c2", "c3"].enumerated() {
                try CompoundChild(
                    id: "link-\(child)", compoundTaskId: "C", childTaskId: child,
                    childIndex: index, createdAt: self.now, updatedAt: self.now,
                    lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
            for (index, taskId) in ["C", "cnt", "n1"].enumerated() {
                try BoardTask(
                    id: "bt-\(taskId)", boardId: self.sourceBoardId, taskId: taskId,
                    row: index / 3, col: index % 3, isCenter: false,
                    createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                    version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
            try self.makeEvent("e-in", taskId: "cnt", delta: 3, at: "2026-09-18T08:00:00.000Z").save(db)
            try self.makeEvent("e-before", taskId: "cnt", delta: 5, at: "2026-09-17T08:00:00.000Z").save(db)
            try self.makeEvent(
                "e-tomb", taskId: "cnt", delta: 4, at: "2026-09-18T08:30:00.000Z", isDeleted: true
            ).save(db)
        }
        return database
    }

    private func makeVM(_ database: AppDatabase, recurring: Bool = false) -> BoardWizardViewModel {
        BoardWizardViewModel(
            preferences: .defaults, startRecurring: recurring, database: database
        )
    }

    /// A one-off wizard with the canonical source board already pulled.
    private func pulledVM(recurring: Bool = false) throws -> BoardWizardViewModel {
        let database = try seedSourceBoard(try makeDb())
        let vm = makeVM(database, recurring: recurring)
        vm.pullBoard(boardId: sourceBoardId)
        return vm
    }

    private func rule(_ vm: BoardWizardViewModel, _ taskId: String) throws -> BoardSourceMemberRule {
        BoardSources.memberRule(
            for: taskId, in: try XCTUnwrap(vm.sources.first { $0.sourceId == sourceBoardId })
        )
    }

    // MARK: - 1. Supply info (RC4 / RC5)

    func test_resolveSupply_windowCountCountsOnlyLiveEventsInsideTheWindow() throws {
        let database = try seedSourceBoard(try makeDb())
        let info = try XCTUnwrap(try database.fetchBoardSourceSupply(boardId: sourceBoardId))

        XCTAssertEqual(info.windowCountByTaskId["cnt"], 3,
                       "the pre-window increment and the tombstoned one are both excluded")
        XCTAssertNil(info.windowCountByTaskId["n1"], "a normal member carries no count")
        XCTAssertNil(info.windowCountByTaskId["C"], "a compound is the documented carve-out")
    }

    func test_resolveSupply_carriesTheSourceBoardsOwnWindow() throws {
        let database = try seedSourceBoard(try makeDb())
        let info = try XCTUnwrap(try database.fetchBoardSourceSupply(boardId: sourceBoardId))

        XCTAssertEqual(
            info.sourceWindow,
            BoardSources.BoardWindow(timeframe: .daily, startDate: windowStart, endDate: windowEnd)
        )
    }

    func test_resolveSupply_emptyBoardStillCarriesItsWindow() throws {
        let database = try makeDb()
        let board = try makeBoard(id: "empty-board", timeframe: .weekly)
        try database.write { db in try board.save(db) }

        let info = try XCTUnwrap(try database.fetchBoardSourceSupply(boardId: "empty-board"))
        XCTAssertTrue(info.supplyTaskIds.isEmpty)
        XCTAssertTrue(info.windowCountByTaskId.isEmpty)
        XCTAssertEqual(info.sourceWindow.timeframe, .weekly)
    }

    // MARK: - 2. RC4 prefill

    func test_pullBoard_oneOff_prefillsCountingMembersWithTheirRemainingTarget() throws {
        // A fresh wizard's window is INDEFINITE (the `.custom` default
        // timeframe resolves to an ongoing board), so its nominal length is
        // unknowable and the 2026-09-21 pro-rating leaves the remaining
        // amount verbatim — see the two window vectors below for the scaled
        // and the same-length cases.
        let vm = try pulledVM()

        XCTAssertEqual(try rule(vm, "cnt").target, 7, "goal 10 − 3 already logged this window")
        XCTAssertNil(try rule(vm, "n1").target, "a normal member is never targeted")
        XCTAssertNil(try rule(vm, "C").target, "a compound member is never targeted")
    }

    /// Owner ruling 2026-09-24 — a board pulled while it has no board open
    /// (`.noWindow`) resolves empty; it must still get its remaining-target
    /// prefill once it resolves live, not be silently skipped. Web twin: the
    /// "left UNSETTLED" case in `useWizardMemberRules.test.ts`.
    func test_pullBoard_whileNoBoardOpen_prefillsOnceItResolvesLive() throws {
        let database = try seedSourceBoard(try makeDb())
        let vm = makeVM(database)
        // The 2026-09-18 source has ended by 09-19 → no board open.
        AppDatabase.sourceClock = { parseISO8601Date("2026-09-19T09:00:00.000Z")! }
        vm.pullBoard(boardId: sourceBoardId)
        XCTAssertEqual(vm.supplyInfoBySourceId[sourceBoardId]?.noBoardForWindow, true)
        XCTAssertNil(try rule(vm, "cnt").target, "nothing to seed yet")

        // It resolves live again (the clock is back inside its window).
        AppDatabase.sourceClock = { parseISO8601Date(self.now)! }
        vm.refreshSourceSupplies(poolsById: [:], tasksById: [:])
        XCTAssertEqual(try rule(vm, "cnt").target, 7, "the owed prefill runs on the first live resolve")
    }

    /// Seeds a MONTHLY source board carrying an untouched goal-30 counter —
    /// the owner's reported case ("Run 30 Miles a Month").
    private func seedMonthlySourceBoard(_ database: AppDatabase) throws {
        let board = try makeBoard(
            id: "monthly-src",
            timeframe: .monthly,
            startDate: "2026-09-01T00:00:00.000Z",
            endDate: "2026-09-30T23:59:59.999Z"
        )
        try database.write { db in
            try board.save(db)
            try self.makeTask("run30", type: .counting, maxCount: 30).save(db)
            try BoardTask(
                id: "bt-run30", boardId: "monthly-src", taskId: "run30",
                row: 0, col: 0, isCenter: false,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
    }

    private func monthlyPullTarget(wizardTimeframe: Timeframe) throws -> Int? {
        let database = try makeDb()
        try seedMonthlySourceBoard(database)
        let vm = makeVM(database)
        vm.timeframe = wizardTimeframe
        vm.pullBoard(boardId: "monthly-src")
        let source = try XCTUnwrap(vm.sources.first { $0.sourceId == "monthly-src" })
        return BoardSources.memberRule(for: "run30", in: source).target
    }

    /// Owner ruling 2026-09-21 — the reported bug. A counter pulled from a
    /// MONTHLY board onto a ONE-OFF DAILY board seeds its remaining amount
    /// PRO-RATED to that day, not the monthly goal.
    func test_pullBoard_oneOff_proRatesTheSeededTargetToTheBoardsWindow() throws {
        XCTAssertEqual(try monthlyPullTarget(wizardTimeframe: .daily), 1,
                       "remaining 30, then ceil(30 × 1 / 30) = 1")
        XCTAssertEqual(try monthlyPullTarget(wizardTimeframe: .weekly), 7,
                       "remaining 30, then ceil(30 × 7 / 30) = 7")
    }

    /// The safety property the ruling rests on: the SAME pull onto a
    /// same-length window is a ratio of 1, so the seed is the plain
    /// remaining amount — every pre-existing one-off pull is unchanged.
    func test_pullBoard_oneOff_sameTimeframeSeedsTheRemainingAmountUnscaled() throws {
        XCTAssertEqual(try monthlyPullTarget(wizardTimeframe: .monthly), 30)
        XCTAssertEqual(try monthlyPullTarget(wizardTimeframe: .yearly), 30,
                       "a LONGER window never scales the seed up either")
    }

    func test_pullBoard_recurring_leavesTheTargetAbsent() throws {
        let vm = try pulledVM(recurring: true)

        XCTAssertNil(try rule(vm, "cnt").target,
                     "a recurring board auto-targets against its own window instead")
        XCTAssertNil(vm.sources.first?.memberRules,
                     "a recurring pull writes no rules at all")
    }

    func test_prefillRemainingTargets_neverOverwritesAnEditedTarget() throws {
        let database = try seedSourceBoard(try makeDb())
        let vm = makeVM(database)
        vm.pullBoard(boardId: sourceBoardId)
        vm.setMemberTarget(sourceId: sourceBoardId, taskId: "cnt", target: 2)

        let info = try XCTUnwrap(try database.fetchBoardSourceSupply(boardId: sourceBoardId))
        vm.prefillRemainingTargets(sourceId: sourceBoardId, info: info)

        XCTAssertEqual(try rule(vm, "cnt").target, 2, "a re-resolve never stomps an edit")
    }

    func test_prefillRemainingTargets_skipsAGoallessCounter() throws {
        let database = try makeDb()
        let board = try makeBoard(id: sourceBoardId)
        try database.write { db in
            try board.save(db)
            try self.makeTask("open", type: .counting, maxCount: nil).save(db)
            try BoardTask(
                id: "bt-open", boardId: self.sourceBoardId, taskId: "open",
                row: 0, col: 0, isCenter: false,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
        let vm = makeVM(database)
        vm.pullBoard(boardId: sourceBoardId)

        XCTAssertNil(vm.sources.first?.memberRules,
                     "a goal-less counter has no remaining target to seed")
    }

    // MARK: - 3. Member actions + pruning

    func test_setMemberTarget_setThenClear_leavesNoMemberRulesKeyAtAll() throws {
        let vm = try pulledVM()
        // Start from a pull that seeded `cnt` — clear it back out.
        vm.setMemberTarget(sourceId: sourceBoardId, taskId: "cnt", target: nil)

        let source = try XCTUnwrap(vm.sources.first)
        XCTAssertNil(source.memberRules)
        let encoded = try XCTUnwrap(
            String(data: try JSONEncoder().encode(source), encoding: .utf8)
        )
        XCTAssertFalse(encoded.contains("memberRules"),
                       "a rule-less source encodes byte-identically to a pre-B1 row")
    }

    func test_setMemberVary_offPrunesTheFieldBackToAnAbsence() throws {
        let vm = try pulledVM(recurring: true)
        vm.setMemberVary(sourceId: sourceBoardId, taskId: "cnt", level: .lot)
        XCTAssertEqual(try rule(vm, "cnt").vary, .lot)

        vm.setMemberVary(sourceId: sourceBoardId, taskId: "cnt", level: .off)
        XCTAssertNil(vm.sources.first?.memberRules, "level 0 is the default — stored as an absence")
    }

    func test_setMemberRules_forAnUnpulledSource_isANoOp() throws {
        let vm = try pulledVM(recurring: true)
        vm.setMemberVary(sourceId: "nope", taskId: "cnt", level: .lot)

        XCTAssertNil(vm.sources.first?.memberRules)
    }

    // MARK: - 4. Split up (RC7) + part rules

    func test_setMemberSplit_raisesAvailableCountAndCapacityByPartsMinusOne() throws {
        let vm = try pulledVM()
        XCTAssertEqual(vm.availableCount(forSourceId: sourceBoardId), 3)
        XCTAssertEqual(vm.sourceCapacity, 3)

        vm.setMemberSplit(sourceId: sourceBoardId, taskId: "C", split: true)

        XCTAssertEqual(vm.availableCount(forSourceId: sourceBoardId), 5, "3 − 1 + 3 parts")
        XCTAssertEqual(vm.sourceCapacity, 5)
        XCTAssertEqual(vm.selectedTaskIds, ["c1", "c2", "c3", "cnt", "n1"])
        XCTAssertFalse(vm.selectedTaskIds.contains("C"), "the compound itself steps aside")
    }

    func test_setPartExcluded_dropsOnePartFromTheSupply() throws {
        let vm = try pulledVM()
        vm.setMemberSplit(sourceId: sourceBoardId, taskId: "C", split: true)

        XCTAssertTrue(vm.setPartExcluded(
            sourceId: sourceBoardId, taskId: "C", childId: "c1", excluded: true
        ))
        XCTAssertEqual(vm.availableCount(forSourceId: sourceBoardId), 4,
                       "3 − 1 + (3 parts − 1 excluded)")
        XCTAssertFalse(vm.selectedTaskIds.contains("c1"))
    }

    func test_setPartExcluded_refusesTheLastIncludedPart() throws {
        let vm = try pulledVM()
        vm.setMemberSplit(sourceId: sourceBoardId, taskId: "C", split: true)
        XCTAssertTrue(vm.setPartExcluded(sourceId: sourceBoardId, taskId: "C", childId: "c1", excluded: true))
        XCTAssertTrue(vm.setPartExcluded(sourceId: sourceBoardId, taskId: "C", childId: "c2", excluded: true))

        XCTAssertFalse(
            vm.setPartExcluded(sourceId: sourceBoardId, taskId: "C", childId: "c3", excluded: true),
            "a split member always contributes at least one square"
        )
        XCTAssertNil(try BoardSources.partRule(for: "c3", in: rule(vm, "C")).excluded,
                     "the refusal writes nothing")
        XCTAssertTrue(vm.selectedTaskIds.contains("c3"))
    }

    func test_splitPartDeselect_sticksInsteadOfComingStraightBack() throws {
        let vm = try pulledVM()
        vm.setMemberSplit(sourceId: sourceBoardId, taskId: "C", split: true)

        vm.toggleTaskSelection("c2")

        XCTAssertFalse(vm.selectedTaskIds.contains("c2"),
                       "a part deselect writes a PART rule, so the recompute can't restore it")
        XCTAssertEqual(try BoardSources.partRule(for: "c2", in: rule(vm, "C")).excluded, true)
        XCTAssertFalse(vm.sources.first?.excludedTaskIds.contains("c2") ?? false,
                       "a part is never named by the compound's own exclude list")
    }

    func test_toggleTaskSelection_refusesToDeselectTheLastIncludedPart() throws {
        let vm = try pulledVM()
        vm.setMemberSplit(sourceId: sourceBoardId, taskId: "C", split: true)
        XCTAssertTrue(vm.toggleTaskSelection("c1"))
        XCTAssertTrue(vm.toggleTaskSelection("c2"))
        let manualBefore = vm.manualTaskIds
        let selectionBefore = vm.selectedTaskIds

        // Final review I1 — the refusal is REPORTED, so the Tasks step can
        // skip its "Removed …" toast (whose Undo would hand-add the part).
        XCTAssertFalse(vm.toggleTaskSelection("c3"))

        XCTAssertTrue(vm.selectedTaskIds.contains("c3"), "the gesture is a no-op, not a flicker")
        XCTAssertEqual(vm.selectedTaskIds, selectionBefore)
        XCTAssertEqual(vm.manualTaskIds, manualBefore,
                       "a refused deselect never touches the hand-added layer")
    }

    func test_toggleSourceExclude_ofASplitCompound_clearsItsPartRules() throws {
        let vm = try pulledVM()
        vm.setMemberSplit(sourceId: sourceBoardId, taskId: "C", split: true)
        vm.setPartExcluded(sourceId: sourceBoardId, taskId: "C", childId: "c1", excluded: true)
        vm.setPartVary(sourceId: sourceBoardId, taskId: "C", childId: "c2", level: .little)

        vm.toggleSourceExclude(sourceId: sourceBoardId, taskId: "C")

        XCTAssertNil(try rule(vm, "C").parts, "RC14 — an excluded member keeps no per-part state")
        XCTAssertEqual(try rule(vm, "C").split, true, "split is the member's shape, and survives")
        XCTAssertEqual(vm.availableCount(forSourceId: sourceBoardId), 2, "only cnt + n1 remain")
    }

    // MARK: - 5. Hand-added dice

    func test_setManualVary_isANoOpForANonCountingTask() throws {
        let database = try seedSourceBoard(try makeDb())
        let vm = makeVM(database)
        vm.toggleTaskSelection("n1")

        vm.setManualVary(taskId: "n1", level: .lot)

        XCTAssertTrue(vm.manualTaskVary.isEmpty, "dice belong to counting rows only")
    }

    func test_setManualVary_worksForAWizardCreatedPendingCounter() throws {
        let database = try makeDb()
        let vm = makeVM(database)
        let pending = makeTask("pending-cnt", type: .counting, maxCount: 8)
        vm.toggleTaskSelection(pending.id)
        vm.addPendingTask(PendingTaskPayload(task: pending, childTasks: [], childLinks: []))

        vm.setManualVary(taskId: pending.id, level: .little)

        XCTAssertEqual(vm.manualTaskVary, ["pending-cnt": .little],
                       "a counter created in the wizard is dice-able before it is ever written")
    }

    func test_setManualVary_offRemovesTheEntry() throws {
        let database = try seedSourceBoard(try makeDb())
        let vm = makeVM(database)
        vm.toggleTaskSelection("cnt")
        vm.setManualVary(taskId: "cnt", level: .lot)
        XCTAssertEqual(vm.manualTaskVary["cnt"], .lot)

        vm.setManualVary(taskId: "cnt", level: .off)

        XCTAssertTrue(vm.manualTaskVary.isEmpty)
    }

    func test_deselectingAHandAddedCounter_prunesItsDice() throws {
        let database = try seedSourceBoard(try makeDb())
        let vm = makeVM(database)
        vm.toggleTaskSelection("cnt")
        vm.setManualVary(taskId: "cnt", level: .lot)

        vm.toggleTaskSelection("cnt")

        XCTAssertTrue(vm.manualTaskVary.isEmpty,
                      "a stale entry would ride into the draft blob and live there forever")
    }

    // MARK: - 6. Reset

    func test_reset_clearsTheRulesLayer() throws {
        let vm = try pulledVM()
        vm.toggleTaskSelection("cnt")
        vm.setManualVary(taskId: "cnt", level: .lot)

        vm.reset()

        XCTAssertTrue(vm.manualTaskVary.isEmpty)
        XCTAssertTrue(vm.childrenByCompoundId.isEmpty)
        XCTAssertTrue(vm.sources.isEmpty)
    }

    // MARK: - 7. Hydration

    /// A resumed draft carrying a SPLIT rule must expand on the FIRST paint —
    /// the static hydration has no links to expand with, so init reloads them
    /// and recomputes. Without that the selection would correct itself a beat
    /// later, on the view's first supply refresh.
    func test_resumedDraft_withASplitRule_expandsOnTheFirstPaint() throws {
        let database = try seedSourceBoard(try makeDb())
        let source = BoardSource(
            sourceId: sourceBoardId, kind: .board, min: 0, max: nil,
            excludedTaskIds: [], filter: .all,
            memberRules: ["C": BoardSourceMemberRule(split: true)]
        )
        let blob = try XCTUnwrap(RecurringDraftMixPayload(
            poolIds: [], manualTaskIds: [], removedTaskIds: [], sources: [source],
            manualTaskVary: ["cnt": .little]
        ).encoded())
        let dict: [String: Any] = [
            "id": "draft-1", "userId": userId, "name": "Draft",
            "status": BoardStatus.draft.rawValue, "boardSize": 3,
            "timeframe": Timeframe.daily.rawValue,
            "startDate": windowStart, "endDate": windowEnd,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
            "recurringDraftMix": blob,
        ]
        let draft = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )

        let vm = BoardWizardViewModel(
            preferences: .defaults, draft: (draft, []), database: database
        )

        XCTAssertEqual(vm.selectedTaskIds, ["c1", "c2", "c3", "cnt", "n1"])
        XCTAssertFalse(vm.selectedTaskIds.contains("C"))
        XCTAssertEqual(vm.manualTaskVary, ["cnt": .little], "the blob's dice hydrate too")
        XCTAssertNil(try rule(vm, "cnt").target,
                     "a hydrated source is never re-seeded by the RC4 prefill")

        // The RC4/RC5 supply fields must arrive WITH the hydration, not on
        // the view's first refresh — a rule row rendered against a nil
        // `sourceWindow` would show the bare goal and then change under the
        // person a beat later.
        let hydratedSupply = try XCTUnwrap(vm.supplyInfoBySourceId[sourceBoardId])
        XCTAssertEqual(
            hydratedSupply.sourceWindow,
            BoardSources.BoardWindow(timeframe: .daily, startDate: windowStart, endDate: windowEnd)
        )
        XCTAssertEqual(hydratedSupply.windowCountByTaskId["cnt"], 3)
    }
}
