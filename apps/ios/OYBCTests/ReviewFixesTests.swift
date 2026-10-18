import XCTest
import GRDB
@testable import OYBC

/// Review-fix PR (C1 / C2 / C3 / C9): repeating-board round-trip of frozen goals, dice around an
/// explicit goal (one-off + recurring), typed-only freezing, and the chip accessibility name.
/// Twin of the web `explicitGoalRoll` / `wizardPlacementParams` additions.
@MainActor
final class ReviewFixesTests: XCTestCase {

    typealias K = LinkedWindowKit

    private func normalTask(_ id: String) -> Task {
        let t = "2026-05-01T00:00:00.000Z"
        return Task(
            id: id, userId: K.userId, title: id, type: .normal,
            totalCompletions: 0, totalInstances: 0, createdAt: t, updatedAt: t, version: 1, isDeleted: false
        )
    }

    // MARK: - C3 — only typed goals freeze

    func testFrozenManualTaskTargets_skipsAnUntypedWindowDefault() {
        let root = K.task("root", maxCount: 30)
        let draft = PlacementParamsDraft(targetOverride: 5, targetKind: .discrete)
        XCTAssertTrue(frozenManualTaskTargets(
            manualTaskIds: ["root"], params: ["root": draft], typedIds: [], tasksById: ["root": root]
        ).isEmpty)
        XCTAssertEqual(
            frozenManualTaskTargets(manualTaskIds: ["root"], params: ["root": draft], typedIds: ["root"], tasksById: ["root": root]),
            ["root": ManualTaskTarget(target: 5, kind: .discrete, title: nil)]
        )
    }

    func testSetPlacementParams_tracksTypedProvenance_andClearDropsIt() throws {
        let db = try AppDatabase.makeTestInstance()
        let vm = BoardWizardViewModel(preferences: .defaults, userId: K.userId, database: db)
        let p = PlacementParamsDraft(targetOverride: 5, targetKind: .discrete)
        vm.setPlacementParams(taskId: "a", p, typed: true)
        vm.setPlacementParams(taskId: "b", p)
        XCTAssertEqual(vm.typedPlacementIds, ["a"])
        vm.setPlacementParams(taskId: "a", nil)
        XCTAssertTrue(vm.typedPlacementIds.isEmpty)
    }

    func testDraftBlob_writesTypedPlacementIds_oldBlobMeansAllTyped_staleIdsDropped() throws {
        let p = PlacementParamsDraft(targetOverride: 5, targetKind: .discrete)
        let mix = RecurringDraftMixPayload(
            poolIds: [], manualTaskIds: ["a", "b"], removedTaskIds: [], sources: [],
            placementParams: ["a": p, "b": p], typedPlacementIds: ["a"]
        )
        let back = RecurringDraftMixPayload.decoded(from: mix.encoded())
        XCTAssertEqual(back.typedPlacementIds, ["a"])
        XCTAssertEqual(back.placementParams, ["a": p, "b": p])

        let old = #"{"v":2,"poolIds":[],"manualTaskIds":["a"],"removedTaskIds":[],"sources":[],"placementParams":{"a":{"targetOverride":5,"targetKind":"discrete"}}}"#
        XCTAssertEqual(RecurringDraftMixPayload.decoded(from: old).typedPlacementIds, ["a"], "no key: freeze-all, as before")

        let stale = #"{"v":2,"poolIds":[],"manualTaskIds":["a"],"removedTaskIds":[],"sources":[],"placementParams":{"a":{"targetOverride":5,"targetKind":"discrete"}},"typedPlacementIds":["a","gone"]}"#
        XCTAssertEqual(RecurringDraftMixPayload.decoded(from: stale).typedPlacementIds, ["a"])

        let empty = RecurringDraftMixPayload(poolIds: [], manualTaskIds: [], removedTaskIds: [], sources: [])
        XCTAssertFalse(try XCTUnwrap(empty.encoded()).contains("typedPlacementIds"), "omitted when there are no params")
    }

    func testRestamp_keepsATypedGoalEvenWhenItEqualsTheOldWindowDefault() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var root = K.task("root", maxCount: 100)
        root.timeframeGoals = CounterTimeframeGoals(daily: 2, weekly: 10)
        try db.saveTask(root)
        let vm = BoardWizardViewModel(preferences: .defaults, userId: K.userId, database: db)
        let daily = CounterPlacement.PickWindow(timeframe: .daily, startDate: "2026-10-14T00:00:00", endDate: "2026-10-14T23:59:59")
        let weekly = CounterPlacement.PickWindow(timeframe: .weekly, startDate: "2026-10-12T00:00:00", endDate: "2026-10-18T23:59:59")
        vm.restampPlacementParams(to: daily)
        vm.setPlacementParams(taskId: "root", PlacementParamsDraft(targetOverride: 2, targetKind: .discrete), typed: true)
        vm.restampPlacementParams(to: weekly)
        XCTAssertEqual(vm.placementParams["root"]?.targetOverride, 2, "typed: never follows the window")
    }

    // MARK: - C1 — editing a repeating board keeps its frozen goals

    func testEditingARepeatingBoard_roundTripsManualTaskTargets() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(K.task("root", maxCount: 30))
        let now = "2026-10-10T00:00:00.000Z"
        let frozen = ["root": ManualTaskTarget(target: 9, kind: .discrete, title: "Nine miles")]
        let template = RecurringBoardTemplate(
            id: "tpl", userId: K.userId, name: "Weekly", timeframe: .weekly, boardSize: 3, centerSquareType: .none,
            isRandomized: false, seedTaskIds: [], poolIds: [], manualTaskIds: ["root"], removedTaskIds: [],
            sources: [], manualTaskTargets: frozen, isActive: true, createdAt: now, updatedAt: now
        )
        try db.saveRecurringBoardTemplateAndEnqueue(template, operation: .create, now: now)

        let vm = BoardWizardViewModel(preferences: .defaults, editingTemplate: template, userId: K.userId, database: db)
        let hydrated = try XCTUnwrap(vm.placementParams["root"])
        XCTAssertEqual(hydrated.targetOverride, 9)
        XCTAssertEqual(hydrated.targetKind, .discrete)
        XCTAssertEqual(hydrated.titleOverride, "Nine miles")
        XCTAssertTrue(vm.typedPlacementIds.contains("root"), "hydrated entries re-freeze on Save")

        let exp = expectation(description: "persist")
        persistRecurringTemplate(
            controller: vm, userId: K.userId, database: db,
            onSuccess: { _ in exp.fulfill() }, onError: { XCTFail($0); exp.fulfill() }
        )
        wait(for: [exp], timeout: 10)

        let stored = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: "tpl"))
        XCTAssertEqual(stored.manualTaskTargets, frozen, "an unrelated edit no longer wipes the frozen goals")
    }

    func testPlacementParamsFromFrozen_dropsIdsThatAreNoLongerHandAdded() {
        let frozen = ["a": ManualTaskTarget(target: 3, kind: .duration, title: nil), "gone": ManualTaskTarget(target: 1, kind: .discrete, title: nil)]
        let out = BoardWizardViewModel.placementParams(fromFrozen: frozen, manualTaskIds: ["a"])
        XCTAssertEqual(Array(out.keys), ["a"])
        XCTAssertEqual(out["a"], PlacementParamsDraft(targetOverride: 3, targetKind: .duration, titleOverride: nil))
    }

    // MARK: - C2 — dice roll around the explicit goal

    func testOverlaying_diceRollAroundTheExplicitGoal() {
        let root = K.task("root", maxCount: 100)
        let planned = BoardSources.PlannedPlacement(taskId: "root", targetOverride: 77, targetKind: .discrete)
        let draft = PlacementParamsDraft(targetOverride: 10, targetKind: .discrete)
        // "A little" = ±20 %: 8...12.
        XCTAssertEqual(draft.overlaying(planned, vary: .little, task: root, rng: { 0 }).targetOverride, 8)
        XCTAssertEqual(draft.overlaying(planned, vary: .little, task: root, rng: { 0.999 }).targetOverride, 12)
        XCTAssertEqual(draft.overlaying(planned, vary: .off, task: root, rng: { 0.999 }).targetOverride, 10,
                       "no dice: the explicit goal as-is")
        XCTAssertEqual(draft.overlaying(planned).targetOverride, 10)
    }

    func testOneOffSave_diceRollAroundATypedGoal() throws {
        func save(vary: VaryLevel, rng: Double) throws -> BoardTask? {
            let db = try AppDatabase.makeTestInstance()
            try K.seedUser(db)
            try db.saveTask(K.task("root", maxCount: 100))
            let start = "2026-10-01T00:00:00.000Z", end = "2026-10-31T23:59:59.000Z"
            try db.saveWizardBoard(
                board: K.board(id: "b1", startDate: start, endDate: end, size: 1),
                boardTasks: [K.placement(id: "bt", boardId: "b1", taskId: "root")],
                pendingTasks: [], isUpdate: false, manualTaskIds: ["root"],
                manualTaskVary: vary == .off ? [:] : ["root": vary],
                placementParams: ["root": PlacementParamsDraft(targetOverride: 10, targetKind: .discrete)],
                now: start, rng: { rng }
            )
            return try db.fetchBoardTasks(boardId: "b1").first
        }
        XCTAssertEqual(try save(vary: .little, rng: 0.999)?.targetOverride, 12)
        XCTAssertEqual(try save(vary: .little, rng: 0)?.targetOverride, 8)
        XCTAssertEqual(try save(vary: .off, rng: 0.999)?.targetOverride, 10)
    }

    func testRecurringSpawn_rerollsAroundTheFrozenTarget() throws {
        func spawn(vary: [String: VaryLevel]?, rng: Double) throws -> BoardTask? {
            let db = try AppDatabase.makeTestInstance()
            try K.seedUser(db)
            let now = "2026-09-18T09:00:00.000Z"
            let ids = ["root", "m1", "m2", "m3"]
            try db.write { d in
                try K.task("root", maxCount: 30).save(d)
                for id in ids.dropFirst() { try self.normalTask(id).save(d) }
            }
            let template = RecurringBoardTemplate(
                id: "tpl", userId: K.userId, name: "Daily", timeframe: .daily, boardSize: 2, centerSquareType: .none,
                isRandomized: false, seedTaskIds: [], manualTaskIds: ids, sources: [],
                manualTaskVary: vary, manualTaskTargets: ["root": ManualTaskTarget(target: 10, kind: .discrete, title: nil)],
                isActive: true, createdAt: now, updatedAt: now
            )
            try db.write { try template.save($0) }
            let outcome = try db.spawnRecurringBoard(
                PendingTemplateSpawn(
                    template: template, windowStart: "2026-09-18T00:00:00.000Z",
                    windowEnd: "2026-09-18T23:59:59.999Z", suggestedName: "Daily"
                ),
                boardId: "spawned", now: now, rng: { rng }
            )
            guard case .spawned = outcome else { XCTFail("expected a spawn, got \(outcome)"); return nil }
            return try db.read { try BoardTask.filter(Column("boardId") == "spawned" && Column("taskId") == "root").fetchOne($0) }
        }
        XCTAssertEqual(try spawn(vary: ["root": .little], rng: 0.999)?.targetOverride, 12)
        XCTAssertEqual(try spawn(vary: ["root": .little], rng: 0)?.targetOverride, 8, "re-rolled per spawn")
        XCTAssertEqual(try spawn(vary: nil, rng: 0.999)?.targetOverride, 10, "no dice: the frozen target as-is")
    }

    // MARK: - C9 — the chip names its unit

    func testChipAccessibilityNames() {
        let tens = CounterLogAmount.TapChip(value: 10, label: "+10", role: .preset)
        let rest = CounterLogAmount.TapChip(value: 8, label: "+8 ✓", role: .rest)
        let other = CounterLogAmount.TapChip(value: nil, label: "Other…", role: .other)
        XCTAssertEqual(TapLogChipRow.accessibilityName(tens, unit: "pages"), "Log +10 pages")
        XCTAssertEqual(TapLogChipRow.accessibilityName(tens, unit: ""), "Log +10")
        XCTAssertEqual(TapLogChipRow.accessibilityName(rest, unit: "pages"), "Log the rest, +8 pages")
        XCTAssertEqual(TapLogChipRow.accessibilityName(other, unit: "pages"), "Log another amount")
    }
}
