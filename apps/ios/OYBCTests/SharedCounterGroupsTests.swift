import XCTest
@testable import OYBC

/// Unit tests for `buildSharedCounterGroups` in `SharedCounterGroups.swift`.
///
/// Swift port of `packages/shared/tests/algorithms/sharedCounterGroups.test.ts`.
/// Both suites cover the same 11 core cases (plus the P5 `isCounter` block
/// below) so drift between the TS source of truth and the Swift port is
/// caught immediately.
///
/// Cases:
///  1. No shared-counter links → empty result.
///  2. Source + one inherit-baseline derived task (all fields).
///  3. Start-from-zero baseline → displayed = count - baseline.
///  4. Baseline exceeds count → clamp to 0.
///  5. DRAFT board → task not-counting (inactive).
///  6. Deleted source task → group skipped.
///  7. Deleted linked task → excluded from member list.
///  8. No live board placement → null board + inactive.
///  9. Same board for both members → boardCount = 1 (distinct).
/// 10. Sort groups by name, case-insensitively.
/// 11. Prefer ACTIVE over DRAFT as primary placement.
///
/// P5 (isCounter, hub-born counters — see below):
/// 12. Flagged zero-link source → single-member group.
/// 13. Flagged source WITH links → one group, not two.
/// 14. Unflagged standalone counting task → still no group.
/// 15. Flagged but DERIVED task (malformed row) → ignored.
final class SharedCounterGroupsTests: XCTestCase {

    // MARK: - Fixtures

    private let ts = "2026-02-01T12:00:00.000Z"
    /// Inside every fixture board's window (`board(_:status:)` ends them
    /// 2026-02-07), so an ACTIVE fixture board is "counting now" whenever
    /// the suite runs — the TS vector runner pins the same instant.
    private let inWindow = SharedCounterMemberVisibility(
        showExpired: true, now: ISO8601DateFormatter().date(from: "2026-02-03T12:00:00Z")!
    )

    /// Minimal counting Task. Mirrors the TS `counter()` fixture.
    private func counter(
        _ id: String,
        title: String? = nil,
        currentCount: CountValue = 0,
        maxCount: CountValue? = nil,
        sharedCounterId: String? = nil,
        baseline: CountValue? = nil,
        timeframe: Timeframe? = nil,
        startDate: String? = nil,
        /// B3 RC9 — a window-stamped derived member carries its board
        /// window's end; the expiry filter reads exactly this.
        endDate: String? = nil,
        isDeleted: Bool = false,
        isCounter: Bool = false,
        // R1 (pair-derived counter names): left nil by default so the
        // pre-existing 15 cases (authored pre-R1) keep asserting on
        // `title` via the CounterName.formatCounterName("") fallback —
        // mirrors the TS fixture's `toTask` (see
        // packages/shared/tests/algorithms/sharedCounterGroups.test.ts).
        // Dedicated pair-derived-name cases below pass explicit values.
        action: String? = nil,
        unit: String? = nil
    ) -> Task {
        Task(
            id: id,
            userId: "u1",
            title: title ?? "Counter \(id)",
            type: .counting,
            action: action,
            unit: unit,
            maxCount: maxCount,
            totalCompletions: 0,
            totalInstances: 0,
            currentCount: currentCount,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: isDeleted,
            timeframe: timeframe,
            startDate: startDate,
            endDate: endDate,
            sharedCounterId: sharedCounterId,
            baseline: baseline,
            isCounter: isCounter
        )
    }

    /// Minimal Board via JSON decode (Board has no explicit memberwise init).
    private func board(
        _ id: String,
        status: BoardStatus,
        timeframe: Timeframe = .weekly
    ) -> Board {
        let data = try! JSONSerialization.data(withJSONObject: boardDict(id, status: status, timeframe: timeframe))
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    /// The JSON dictionary `board(_:status:timeframe:)` decodes — for cases
    /// that need an extra field (`sealedAt`, a different `endDate`).
    private func boardDict(
        _ id: String,
        status: BoardStatus,
        timeframe: Timeframe = .weekly
    ) -> [String: Any] {
        [
            "id": id,
            "userId": "u1",
            "name": "Board \(id)",
            "status": status.rawValue,
            "boardSize": 5,
            "timeframe": timeframe.rawValue,
            "startDate": ts,
            "endDate": "2026-02-07T12:00:00.000Z",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": 25,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": ts,
            "updatedAt": ts,
            "version": 1,
            "isDeleted": false,
        ]
    }

    /// Minimal BoardTask placement.
    private func placement(_ taskId: String, _ boardId: String) -> BoardTask {
        BoardTask(
            id: "bt-\(taskId)-\(boardId)",
            boardId: boardId,
            taskId: taskId,
            row: 0,
            col: 0,
            isCenter: false,
            createdAt: ts,
            updatedAt: ts,
            version: 1
        )
    }

    // MARK: - "Counting now" is the in-play rule (sharedCounterGroups.test.ts twin)

    func test_memberOnEndedOrClosedActiveBoard_isNotCountingNow() {
        let source = counter("src", currentCount: 10, isCounter: true)
        let member = counter("m", currentCount: 10, maxCount: 5, sharedCounterId: "src", baseline: 0)
        let ended = board("ended", status: .active) // endDate 2026-02-07
        var closedDict = boardDict("closed", status: .active)
        closedDict["endDate"] = "2026-02-28T12:00:00.000Z"
        closedDict["sealedAt"] = "2026-02-05T12:00:00.000Z"
        let closed = try! JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: closedDict))
        let iso = ISO8601DateFormatter()
        func build(_ now: String) -> SharedCounterGroup {
            buildSharedCounterGroups(
                tasks: [source, member],
                boardTasks: [placement("src", "ended"), placement("m", "closed")],
                boards: [ended, closed],
                memberVisibility: SharedCounterMemberVisibility(showExpired: true, now: iso.date(from: now)!)
            )[0]
        }
        // Inside the window: the stored status and the in-play rule agree.
        let live = build("2026-02-03T12:00:00Z")
        XCTAssertTrue(live.tasks.first { $0.taskId == "src" }!.isActive)
        XCTAssertFalse(live.tasks.first { $0.taskId == "m" }!.isActive) // closed
        XCTAssertEqual(live.activeTaskCount, 1)
        // After the window: still `status: active` in the row, no longer counting now.
        let later = build("2026-03-01T12:00:00Z")
        XCTAssertFalse(later.tasks.first { $0.taskId == "src" }!.isActive)
        XCTAssertEqual(later.tasks.first { $0.taskId == "src" }!.boardId, "ended")
        XCTAssertEqual(later.activeTaskCount, 0)
    }

    func test_aTaskOnTwoBoardsIsTwoCards_theEndedOneNotCountingNow() {
        let source = counter("src", currentCount: 10, isCounter: true)
        var endedDict = boardDict("ended", status: .active) // newer, ACTIVE, but ended
        endedDict["startDate"] = "2026-02-08T12:00:00.000Z"
        endedDict["endDate"] = "2026-02-14T12:00:00.000Z"
        var openDict = boardDict("open", status: .active) // older, still open
        openDict["startDate"] = "2026-01-01T12:00:00.000Z"
        openDict["endDate"] = "2026-12-31T12:00:00.000Z"
        let decode = { (d: [String: Any]) in try! JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: d)) }
        let groups = buildSharedCounterGroups(
            tasks: [source],
            boardTasks: [placement("src", "ended"), placement("src", "open")],
            boards: [decode(endedDict), decode(openDict)],
            memberVisibility: SharedCounterMemberVisibility(
                showExpired: true, now: ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z")!
            )
        )
        // Slice 2b: cards ARE placements — one per board, the ended one not counting now.
        XCTAssertEqual(groups[0].tasks.map(\.boardId), ["ended", "open"])
        XCTAssertEqual(groups[0].tasks.map(\.isActive), [false, true])
        XCTAssertEqual(groups[0].taskCount, 1)
        XCTAssertEqual(groups[0].boardCount, 2)
    }

    // MARK: - 1. No shared-counter links

    func test_returnsEmpty_whenNoSharedCounterLinks() {
        let tasks = [counter("a", currentCount: 5)] // standalone, no link
        let groups = buildSharedCounterGroups(tasks: tasks, boardTasks: [], boards: [])
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - 2. Source + one inherit-baseline derived task

    func test_groupsSourceAndOneInheritBaselineDerived() {
        let src = counter("src", title: "Push-ups", currentCount: 512, maxCount: 1000)
        let der = counter("der", maxCount: 30, sharedCounterId: "src", baseline: 0)
        let bWeekly = board("bw", status: .active, timeframe: .weekly)
        let bMonthly = board("bm", status: .active, timeframe: .monthly)

        let groups = buildSharedCounterGroups(
            tasks: [src, der],
            boardTasks: [placement("src", "bm"), placement("der", "bw")],
            boards: [bWeekly, bMonthly],
            memberVisibility: inWindow
        )

        XCTAssertEqual(groups.count, 1)
        let g = groups[0]
        XCTAssertEqual(g.counterId, "src")
        XCTAssertEqual(g.name, "Push-ups")
        XCTAssertEqual(g.lifetime, 512)
        XCTAssertEqual(g.taskCount, 2)
        XCTAssertEqual(g.boardCount, 2)
        XCTAssertEqual(g.activeTaskCount, 2)

        // Source first, baseline 0 → displayed = 512, goal 1000 → not met.
        let sourceView = g.tasks[0]
        XCTAssertTrue(sourceView.isSource)
        XCTAssertEqual(sourceView.logged, 512)
        XCTAssertEqual(sourceView.goal, 1000)
        XCTAssertFalse(sourceView.met)
        XCTAssertEqual(sourceView.boardName, "Board bm")

        // Derived inherit (baseline 0) → displayed = 512, goal 30 → met, 482 over.
        let derivedView = g.tasks[1]
        XCTAssertFalse(derivedView.isSource)
        XCTAssertEqual(derivedView.logged, 512)
        XCTAssertEqual(derivedView.goal, 30)
        XCTAssertTrue(derivedView.met)
        XCTAssertEqual(derivedView.over, 482)
    }

    // MARK: - 3. Start-from-zero baseline

    func test_appliesStartFromZeroBaseline() {
        let src = counter("src", currentCount: 100)
        // Linked when source was at 70 → baseline 70 → displayed = 100 - 70 = 30.
        let der = counter("der", maxCount: 50, sharedCounterId: "src", baseline: 70)
        let groups = buildSharedCounterGroups(
            tasks: [src, der], boardTasks: [placement("src", "b1"), placement("der", "b1")], boards: [board("b1", status: .active)]
        )

        let derived = groups[0].tasks.first { $0.taskId == "der" }!
        XCTAssertEqual(derived.logged, 30)
        XCTAssertEqual(derived.goal, 50)
        XCTAssertFalse(derived.met)
    }

    // MARK: - 4. Baseline exceeds count → clamp to 0

    func test_clampsToZeroWhenBaselineExceedsCount() {
        let src = counter("src", currentCount: 20)
        let der = counter("der", maxCount: 10, sharedCounterId: "src", baseline: 50)
        let groups = buildSharedCounterGroups(
            tasks: [src, der], boardTasks: [placement("src", "b1"), placement("der", "b1")], boards: [board("b1", status: .active)]
        )

        let derived = groups[0].tasks.first { $0.taskId == "der" }!
        XCTAssertEqual(derived.logged, 0)
        XCTAssertFalse(derived.met)
        XCTAssertEqual(derived.over, 0)
    }

    // MARK: - 5. DRAFT board → task inactive

    func test_marksTaskOnDraftBoardAsInactive() {
        let src = counter("src", currentCount: 40)
        let der = counter("der", maxCount: 30, sharedCounterId: "src", baseline: 0)
        let groups = buildSharedCounterGroups(
            tasks: [src, der],
            boardTasks: [placement("src", "active"), placement("der", "draft")],
            boards: [board("active", status: .active), board("draft", status: .draft)],
            memberVisibility: inWindow
        )

        let g = groups[0]
        XCTAssertEqual(g.activeTaskCount, 1)
        XCTAssertTrue(g.tasks.first { $0.taskId == "src" }!.isActive)
        XCTAssertFalse(g.tasks.first { $0.taskId == "der" }!.isActive)
    }

    // MARK: - 6. Deleted source → group skipped

    func test_skipsGroupWhoseSourceIsDeleted() {
        let src = counter("src", currentCount: 5, isDeleted: true)
        let der = counter("der", maxCount: 3, sharedCounterId: "src", baseline: 0)
        let groups = buildSharedCounterGroups(tasks: [src, der], boardTasks: [], boards: [])
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - 7. Deleted linked task excluded

    func test_excludesDeletedLinkedTasksFromMemberList() {
        let src = counter("src", currentCount: 10)
        let der1 = counter("der1", maxCount: 5, sharedCounterId: "src", baseline: 0)
        let der2 = counter("der2", maxCount: 5, sharedCounterId: "src", baseline: 0, isDeleted: true)
        let groups = buildSharedCounterGroups(
            tasks: [src, der1, der2],
            boardTasks: [placement("src", "b1"), placement("der1", "b1"), placement("der2", "b1")],
            boards: [board("b1", status: .active)]
        )

        XCTAssertEqual(groups[0].taskCount, 2) // source + der1 only
        let taskIds = Set(groups[0].tasks.map { $0.taskId })
        XCTAssertEqual(taskIds, ["src", "der1"])
    }

    // MARK: - 8. No live board placement → null board + inactive

    func test_unplacedLinkedMemberHasNoCard() {
        let src = counter("src", currentCount: 10)
        let der = counter("der", maxCount: 5, sharedCounterId: "src", baseline: 0)
        let groups = buildSharedCounterGroups(
            tasks: [src, der],
            boardTasks: [placement("src", "b1")],
            boards: [board("b1", status: .active)]
        )

        // Slice 2b: cards are placements — an unplaced linked task has none.
        XCTAssertNil(groups[0].tasks.first { $0.taskId == "der" })
        XCTAssertEqual(groups[0].tasks.map(\.taskId), ["src"])
        XCTAssertEqual(groups[0].taskCount, 1)
    }

    // MARK: - 9. Distinct boards for boardCount

    func test_countDistinctBoardsNotPlacements() {
        let src = counter("src", currentCount: 10)
        let der = counter("der", maxCount: 5, sharedCounterId: "src", baseline: 0)
        // Both members resolve to the same board.
        let groups = buildSharedCounterGroups(
            tasks: [src, der],
            boardTasks: [placement("src", "b1"), placement("der", "b1")],
            boards: [board("b1", status: .active)]
        )
        XCTAssertEqual(groups[0].boardCount, 1)
    }

    // MARK: - 10. Sort groups by name, case-insensitively

    func test_sortsGroupsByNameCaseInsensitively() {
        let zSrc = counter("z", title: "zebra", currentCount: 1)
        let zDer = counter("zd", maxCount: 1, sharedCounterId: "z", baseline: 0)
        let aSrc = counter("a", title: "Apple", currentCount: 1)
        let aDer = counter("ad", maxCount: 1, sharedCounterId: "a", baseline: 0)

        let groups = buildSharedCounterGroups(
            tasks: [zSrc, zDer, aSrc, aDer],
            boardTasks: [],
            boards: []
        )
        XCTAssertEqual(groups.map { $0.name }, ["Apple", "zebra"])
    }

    // MARK: - 11. Prefer ACTIVE over DRAFT as primary placement

    func test_aTaskOnADraftAndAnActiveBoardIsTwoCards() {
        let src = counter("src", currentCount: 10, maxCount: 5)
        let der = counter("der", maxCount: 5, sharedCounterId: "src", baseline: 0)
        let groups = buildSharedCounterGroups(
            tasks: [src, der],
            boardTasks: [placement("src", "draft"), placement("src", "active")],
            boards: [board("draft", status: .draft), board("active", status: .active)],
            memberVisibility: inWindow
        )

        // Slice 2b: one card per placement — the draft one not counting now.
        let cards = groups[0].tasks.filter { $0.taskId == "src" }
        XCTAssertEqual(cards.map(\.boardId), ["active", "draft"])
        XCTAssertEqual(cards.map(\.isActive), [true, false])
        XCTAssertEqual(groups[0].boardCount, 2)
    }

    // MARK: - P5. Hub-born counters (isCounter)
    //
    // Swift port of the TS `describe('hub-born counters (P5)')` block in
    // `packages/shared/tests/algorithms/sharedCounterGroups.test.ts`.

    func test_flaggedZeroLinkSource_isAGroupWhoseCardsAreItsPlacements() {
        let source = counter("c1", title: "Counter c1", currentCount: 500, isCounter: true)
        let groups = buildSharedCounterGroups(tasks: [source], boardTasks: [], boards: [])

        XCTAssertEqual(groups.count, 1)
        let group = groups[0]
        XCTAssertEqual(group.counterId, "c1")
        XCTAssertEqual(group.lifetime, 500)
        // Slice 2b: cards are placements — an unplaced root has a group and no card.
        XCTAssertEqual(group.taskCount, 0)
        XCTAssertEqual(group.boardCount, 0)
        XCTAssertEqual(group.tasks.count, 0)

        let placed = buildSharedCounterGroups(
            tasks: [source], boardTasks: [placement("c1", "b1")], boards: [board("b1", status: .active)]
        )
        XCTAssertEqual(placed[0].tasks.count, 1)
        XCTAssertTrue(placed[0].tasks[0].isSource)
        XCTAssertEqual(placed[0].tasks[0].boardTaskId, placement("c1", "b1").id)
        XCTAssertEqual(placed[0].tasks[0].goal, 0)
        XCTAssertFalse(placed[0].tasks[0].met)
        XCTAssertNil(placed[0].tasks[0].viaCompoundId)
    }

    func test_flaggedSourceWithLinks_producesOneGroupNotTwo() {
        let source = counter("src", title: "Counter src", currentCount: 200, isCounter: true)
        let linked = counter("der", title: "Counter der", maxCount: 50, sharedCounterId: "src", baseline: 0)
        let groups = buildSharedCounterGroups(tasks: [source, linked], boardTasks: [], boards: [])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].counterId, "src")
        XCTAssertEqual(groups[0].tasks.count, 0) // nothing placed → no cards
    }

    func test_unflaggedStandaloneCountingTask_stillProducesNoGroup() {
        let standalone = counter("a", title: "Counter a", currentCount: 5)
        let groups = buildSharedCounterGroups(tasks: [standalone], boardTasks: [], boards: [])
        XCTAssertTrue(groups.isEmpty)
    }

    func test_flaggedButDerivedTask_isIgnored() {
        // Malformed: isCounter + sharedCounterId set together — validators
        // reject the combination at create-input time, but the pure
        // read-model is defensive against a row that slipped through anyway.
        let malformed = counter(
            "mal", title: "Counter mal", currentCount: 10,
            sharedCounterId: "missing-source", baseline: 0, isCounter: true
        )
        let groups = buildSharedCounterGroups(tasks: [malformed], boardTasks: [], boards: [])
        XCTAssertNil(groups.first { $0.counterId == "mal" })
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Pair-derived counter names (R1 counters refresh)
    //
    // Mirrors the TS `describe('pair-derived counter names (R1)')` block in
    // `packages/shared/tests/algorithms/sharedCounterGroups.test.ts`. Task-1
    // coverage note: `sharedCounterGroupsVectors.json` has no action/unit
    // fields, so `SharedCounterGroupsVectorTests` never exercises this path
    // — these three cases are the actual coverage for pair-derivation
    // flowing through `buildSharedCounterGroups`.

    func test_derivesGroupName_fromSourcesActionUnitPair_elidingDefaultDo() {
        let source = counter(
            "src", title: "Fallback title (should not be used)", currentCount: 40,
            isCounter: true, action: "Do", unit: "push-ups"
        )
        let groups = buildSharedCounterGroups(tasks: [source], boardTasks: [], boards: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Push-ups")
    }

    func test_keepsNonDoVerb_inTheDerivedName() {
        let source = counter(
            "src", title: "Fallback title (should not be used)", currentCount: 10,
            isCounter: true, action: "Run", unit: "miles"
        )
        let groups = buildSharedCounterGroups(tasks: [source], boardTasks: [], boards: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Run miles")
    }

    func test_fallsBackToStoredTitle_whenPairCannotProduceAName() {
        let source = counter("src2", title: "Stored Title", currentCount: 10, isCounter: true)
        let groups = buildSharedCounterGroups(tasks: [source], boardTasks: [], boards: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Stored Title")
    }

    // MARK: - 16. RC9 — expired-member visibility (`memberVisibility`)
    //
    // Mirror of the TS "memberVisibility (hub expired filter)" block. The
    // rule lives in the kernel and runs AFTER root detection, so a root
    // never disappears when its members expire (the
    // hub-root-hidden-when-members-expire bug — the old `filterCounterTasks`
    // ran before grouping and un-rooted a board-born counter).

    /// Fixed "now" for the expiry cases: every date below sits an
    /// unambiguous distance either side of it.
    private var rc9Now: Date {
        ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z")!
    }

    private var hideExpired: SharedCounterMemberVisibility {
        SharedCounterMemberVisibility(showExpired: false, now: rc9Now)
    }

    func test_memberVisibility_keepsARootWhoseOnlyMemberExpired_asACardLessGroup() {
        // The board-born case: a plain counting task (not `isCounter`) that
        // is a root purely because a derived weekly row links to it.
        let root = counter("root", currentCount: 40)
        let expired = counter(
            "expired", sharedCounterId: "root", endDate: "2026-02-07T23:59:59.999Z"
        )

        let groups = buildSharedCounterGroups(
            tasks: [root, expired], boardTasks: [placement("expired", "b-old")], boards: [board("b-old", status: .active)],
            memberVisibility: hideExpired
        )

        XCTAssertEqual(groups.map(\.counterId), ["root"], "the root stays listed")
        XCTAssertEqual(groups.first?.lifetime, 40)
        // Slice 2b: cards are placements — the hidden member's card is gone, the root has none.
        XCTAssertEqual(groups.first?.taskCount, 0)
        XCTAssertEqual(groups.first?.activeTaskCount, 0)
        XCTAssertEqual(groups.first?.tasks.map(\.taskId), [])
    }

    func test_memberVisibility_dropsOnlyTheExpiredMember() {
        let root = counter("root", currentCount: 40)
        let live = counter(
            "live", sharedCounterId: "root", endDate: "2026-03-31T23:59:59.999Z"
        )
        let expired = counter(
            "expired", sharedCounterId: "root", endDate: "2026-02-07T23:59:59.999Z"
        )

        let groups = buildSharedCounterGroups(
            tasks: [root, live, expired],
            boardTasks: [placement("live", "b-live"), placement("expired", "b-old")],
            boards: [board("b-live", status: .active), board("b-old", status: .active)],
            memberVisibility: hideExpired
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.tasks.map(\.taskId), ["live"],
                       "only the member whose window has ended is dropped")
        XCTAssertEqual(groups.first?.taskCount, 1)
    }

    func test_memberVisibility_showExpiredListsEveryMember() {
        let root = counter("root", currentCount: 40)
        let live = counter(
            "live", sharedCounterId: "root", endDate: "2026-03-31T23:59:59.999Z"
        )
        let expired = counter(
            "expired", sharedCounterId: "root", endDate: "2026-02-07T23:59:59.999Z"
        )

        let groups = buildSharedCounterGroups(
            tasks: [root, live, expired],
            boardTasks: [placement("live", "b-live"), placement("expired", "b-old")],
            boards: [board("b-live", status: .active), board("b-old", status: .active)],
            memberVisibility: SharedCounterMemberVisibility(showExpired: true, now: rc9Now)
        )

        // Cards by board name ("Board b-live" < "Board b-old").
        XCTAssertEqual(groups.first?.tasks.map(\.taskId), ["live", "expired"])
    }

    func test_memberVisibility_neverHidesARootHoweverOldItsOwnEndDate() {
        // A root with a long-past endDate: it IS the counter, so it stays
        // listed with its lifetime total.
        let root = counter("root", currentCount: 12, endDate: "2020-01-01T00:00:00.000Z")
        let expired = counter(
            "expired", sharedCounterId: "root", endDate: "2026-02-07T23:59:59.999Z"
        )

        let groups = buildSharedCounterGroups(
            tasks: [root, expired], boardTasks: [], boards: [], memberVisibility: hideExpired
        )

        XCTAssertEqual(groups.map(\.counterId), ["root"])
        XCTAssertEqual(groups.first?.lifetime, 12)
    }

    func test_memberVisibility_keepsADatelessDerivedMember() {
        let root = counter("root", currentCount: 40)
        // No endDate at all — "indefinite", never expired (TaskExpiry).
        let member = counter("member", sharedCounterId: "root")

        let groups = buildSharedCounterGroups(
            tasks: [root, member], boardTasks: [placement("member", "b-live")], boards: [board("b-live", status: .active)],
            memberVisibility: hideExpired
        )

        XCTAssertEqual(groups.first?.tasks.map(\.taskId), ["member"])
    }

    func test_memberVisibility_nilListsEveryLiveMember() {
        let root = counter("root", currentCount: 40)
        let expired = counter(
            "expired", sharedCounterId: "root", endDate: "2026-02-07T23:59:59.999Z"
        )

        let groups = buildSharedCounterGroups(
            tasks: [root, expired], boardTasks: [placement("expired", "b-old")], boards: [board("b-old", status: .active)]
        )

        XCTAssertEqual(groups.first?.tasks.map(\.taskId), ["expired"])
    }

    // MARK: - sharedCounterRootIds (the extracted family-root test)

    /// Owner ruling 2026-09-22 — the library's "does this task head a family?"
    /// test, extracted from `buildSharedCounterGroups`. Mirror of
    /// `sharedCounterGroups.test.ts`.
    func test_sharedCounterRootIds_linkRootAndHubBornOnly() {
        let linkRoot = counter("link-root", maxCount: 10)
        let member = counter("member", maxCount: 5, sharedCounterId: "link-root")
        let hubBorn = counter("hub-born", maxCount: 10, isCounter: true)
        let plain = counter("plain", maxCount: 10) // standalone — heads no family
        let ghostTarget = counter("ghost-target", maxCount: 10)
        let deletedMember = counter(
            "deleted-member", maxCount: 5, sharedCounterId: "ghost-target", isDeleted: true
        )

        let roots = sharedCounterRootIds(
            [linkRoot, member, hubBorn, plain, ghostTarget, deletedMember]
        )

        XCTAssertEqual(roots, ["link-root", "hub-born"])
    }

    /// A dangling link must not conjure a family whose hub page would be empty.
    func test_sharedCounterRootIds_ignoresAbsentDeletedAndNonCountingTargets() {
        let memberOfMissing = counter("member-of-missing", sharedCounterId: "never-synced")
        let deletedRoot = counter("deleted-root", isDeleted: true)
        let memberOfDeleted = counter("member-of-deleted", sharedCounterId: "deleted-root")
        var normalRoot = counter("normal-root")
        normalRoot.type = .normal
        let memberOfNormal = counter("member-of-normal", sharedCounterId: "normal-root")

        let roots = sharedCounterRootIds([
            memberOfMissing, deletedRoot, memberOfDeleted, normalRoot, memberOfNormal
        ])

        XCTAssertEqual(roots, [])
    }

    /// The helper and the hub must not drift, in BOTH directions: no group
    /// without a root, and no root without a group. `computeBrowsableTasks`
    /// hides a member on the strength of this set, so a one-way check would
    /// let a root exist that the hub never renders.
    func test_sharedCounterRootIds_agreesWithTheHub() {
        let linkRoot = counter("link-root", maxCount: 10)
        let member = counter("member", maxCount: 5, sharedCounterId: "link-root")
        let hubBorn = counter("hub-born", maxCount: 10, isCounter: true)
        let plain = counter("plain", maxCount: 10)
        // Orphan links of every flavour: none may head a group, none a root.
        let memberOfMissing = counter("member-of-missing", sharedCounterId: "never-synced")
        let deletedRoot = counter("deleted-root", isDeleted: true)
        let memberOfDeleted = counter("member-of-deleted", sharedCounterId: "deleted-root")
        var normalRoot = counter("normal-root")
        normalRoot.type = .normal
        let memberOfNormal = counter("member-of-normal", sharedCounterId: "normal-root")
        let tasks = [
            linkRoot, member, hubBorn, plain,
            memberOfMissing, deletedRoot, memberOfDeleted, normalRoot, memberOfNormal
        ]

        let groups = buildSharedCounterGroups(tasks: tasks, boardTasks: [], boards: [])
        XCTAssertEqual(Set(groups.map { $0.counterId }), ["link-root", "hub-born"])
        XCTAssertEqual(Set(groups.map { $0.counterId }), sharedCounterRootIds(tasks))
    }

    func test_memberVisibility_aHiddenMemberContributesNoBoardRowOrActiveCount() {
        // The member is dropped before the member-view pass, so it can't
        // contribute a board row or an active count to the group.
        let root = counter("root", currentCount: 40, isCounter: true)
        let expired = counter(
            "expired", sharedCounterId: "root", endDate: "2026-02-07T23:59:59.999Z"
        )
        let oldWeek = board("b-old", status: .active)
        let withExpired = buildSharedCounterGroups(
            tasks: [root, expired], boardTasks: [placement("expired", "b-old")], boards: [oldWeek]
        )
        XCTAssertEqual(withExpired.first?.taskCount, 1, "the placed member's card without the rule")
        XCTAssertEqual(withExpired.first?.boardCount, 1)

        let filtered = buildSharedCounterGroups(
            tasks: [root, expired], boardTasks: [placement("expired", "b-old")], boards: [oldWeek],
            memberVisibility: hideExpired
        )
        XCTAssertEqual(filtered.first?.taskCount, 0, "the expired member never reaches the group")
        XCTAssertEqual(filtered.first?.boardCount, 0)
        XCTAssertEqual(filtered.first?.activeTaskCount, 0)
    }
}
