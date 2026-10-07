import XCTest
import GRDB
@testable import OYBC

final class StagedTaskEditsKindTests: XCTestCase {
    private func seeded(kind: CountKind?, maxCount: CountValue) throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance(); try LinkedWindowKit.seedUser(db)
        var t = LinkedWindowKit.task("r", maxCount: maxCount, title: "Run 26 miles"); t.countKind = kind
        try db.saveTask(t)
        return db
    }

    private func patch(goal: String, kind: CountKind) -> TaskEditPatch {
        var p = TaskEditPatch(title: "")
        p.action = "Run"; p.unit = "miles"; p.goal = goal; p.countKind = kind
        return p
    }

    func testStagedSwitchAndDecimalGoalLandTogether() throws {
        let db = try seeded(kind: nil, maxCount: 26)
        try db.write { try AppDatabase.applyStagedTaskEdits(db: $0, stagedEdits: ["r": patch(goal: "26.2", kind: .continuous)], strict: true, now: "2026-10-07T12:00:00.000Z") }
        let row = try XCTUnwrap(db.fetchTask(id: "r"))
        XCTAssertEqual(row.countKind, .continuous)
        XCTAssertEqual(row.maxCount, 26.2)
        XCTAssertEqual(row.title, "Run 26.2 miles")
    }

    func testStrictRejectsAGoalInvalidAtTheStagedKind() throws {
        let db = try seeded(kind: .continuous, maxCount: 26.2)
        XCTAssertThrowsError(try db.write { try AppDatabase.applyStagedTaskEdits(db: $0, stagedEdits: ["r": patch(goal: "26.2", kind: .discrete)], strict: true, now: "2026-10-07T12:00:00.000Z") })
        XCTAssertEqual(try db.fetchTask(id: "r")?.countKind, .continuous)
    }

    func testValidSwitchRollsBackWhenALaterStagedEditFailsStrictMode() throws {
        let db = try seeded(kind: .continuous, maxCount: 26.2)
        let before = try db.read { try SyncQueueItem.fetchCount($0) }
        // Edits apply in sorted-id order: "r" (valid switch) first, then "z" (no such task).
        let edits: [String: TaskEditPatch] = ["r": patch(goal: "26", kind: .discrete), "z": TaskEditPatch(title: "x")]
        XCTAssertThrowsError(try db.write {
            try AppDatabase.applyStagedTaskEdits(db: $0, stagedEdits: edits, strict: true, now: "2026-10-07T12:00:00.000Z")
        })
        let row = try XCTUnwrap(db.fetchTask(id: "r"))
        XCTAssertEqual(row.countKind, .continuous)
        XCTAssertEqual(row.version, 1)
        XCTAssertEqual(try db.read { try SyncQueueItem.fetchCount($0) }, before)
    }

    func testAppliedNeverGivesALinkedRowAKind() {
        var linked = LinkedWindowKit.task("c", maxCount: 6.2, sharedCounterId: "root", baseline: 0); linked.countKind = .continuous
        XCTAssertEqual(patch(goal: "6", kind: .discrete).applied(to: linked).countKind, .continuous)
    }

    func testConfirmedContinuousToDiscreteSwitchRoundsTheStoredRow() throws {
        let db = try seeded(kind: .continuous, maxCount: 26.2)
        try db.write { try AppDatabase.applyStagedTaskEdits(db: $0, stagedEdits: ["r": patch(goal: "26", kind: .discrete)], strict: true, now: "2026-10-07T12:00:00.000Z") }
        let row = try XCTUnwrap(db.fetchTask(id: "r"))
        XCTAssertEqual(row.countKind, .discrete)
        XCTAssertEqual(row.maxCount, 26)
    }
}
