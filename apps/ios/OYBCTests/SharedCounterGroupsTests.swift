import XCTest
@testable import OYBC

/// Unit tests for `buildSharedCounterGroups` in `SharedCounterGroups.swift`.
///
/// Swift port of `packages/shared/tests/algorithms/sharedCounterGroups.test.ts`.
/// Both suites cover the same 11 cases so drift between the TS source of truth
/// and the Swift port is caught immediately.
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
final class SharedCounterGroupsTests: XCTestCase {

    // MARK: - Fixtures

    private let ts = "2026-02-01T12:00:00.000Z"

    /// Minimal counting Task. Mirrors the TS `counter()` fixture.
    private func counter(
        _ id: String,
        title: String? = nil,
        currentCount: Int = 0,
        maxCount: Int? = nil,
        sharedCounterId: String? = nil,
        baseline: Int? = nil,
        timeframe: Timeframe? = nil,
        startDate: String? = nil,
        isDeleted: Bool = false
    ) -> Task {
        Task(
            id: id,
            userId: "u1",
            title: title ?? "Counter \(id)",
            type: .counting,
            action: "Do",
            unit: "reps",
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
            sharedCounterId: sharedCounterId,
            baseline: baseline
        )
    }

    /// Minimal Board via JSON decode (Board has no explicit memberwise init).
    private func board(
        _ id: String,
        status: BoardStatus,
        timeframe: Timeframe = .weekly
    ) -> Board {
        let dict: [String: Any] = [
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
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
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
            boards: [bWeekly, bMonthly]
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
        let groups = buildSharedCounterGroups(tasks: [src, der], boardTasks: [], boards: [])

        let derived = groups[0].tasks.first { $0.taskId == "der" }!
        XCTAssertEqual(derived.logged, 30)
        XCTAssertEqual(derived.goal, 50)
        XCTAssertFalse(derived.met)
    }

    // MARK: - 4. Baseline exceeds count → clamp to 0

    func test_clampsToZeroWhenBaselineExceedsCount() {
        let src = counter("src", currentCount: 20)
        let der = counter("der", maxCount: 10, sharedCounterId: "src", baseline: 50)
        let groups = buildSharedCounterGroups(tasks: [src, der], boardTasks: [], boards: [])

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
            boards: [board("active", status: .active), board("draft", status: .draft)]
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
        let groups = buildSharedCounterGroups(tasks: [src, der1, der2], boardTasks: [], boards: [])

        XCTAssertEqual(groups[0].taskCount, 2) // source + der1 only
        let taskIds = Set(groups[0].tasks.map { $0.taskId })
        XCTAssertEqual(taskIds, ["src", "der1"])
    }

    // MARK: - 8. No live board placement → null board + inactive

    func test_memberWithNoBoardPlacementHasNullBoardAndIsInactive() {
        let src = counter("src", currentCount: 10)
        let der = counter("der", maxCount: 5, sharedCounterId: "src", baseline: 0)
        let groups = buildSharedCounterGroups(
            tasks: [src, der],
            boardTasks: [placement("src", "b1")],
            boards: [board("b1", status: .active)]
        )

        let derived = groups[0].tasks.first { $0.taskId == "der" }!
        XCTAssertNil(derived.boardId)
        XCTAssertNil(derived.boardName)
        XCTAssertFalse(derived.isActive)
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

    func test_prefersActiveBoardOverDraftForPrimaryPlacement() {
        let src = counter("src", currentCount: 10, maxCount: 5)
        let der = counter("der", maxCount: 5, sharedCounterId: "src", baseline: 0)
        let groups = buildSharedCounterGroups(
            tasks: [src, der],
            boardTasks: [placement("src", "draft"), placement("src", "active")],
            boards: [board("draft", status: .draft), board("active", status: .active)]
        )

        let sourceView = groups[0].tasks.first { $0.taskId == "src" }!
        XCTAssertEqual(sourceView.boardId, "active")
        XCTAssertTrue(sourceView.isActive)
    }
}
