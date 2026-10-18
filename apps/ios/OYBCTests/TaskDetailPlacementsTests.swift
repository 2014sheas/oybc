import XCTest
import GRDB
@testable import OYBC

/// Task Detail PR 5 — placement resolution. Twin of the web
/// `loadTaskDetailPlacements` tests in `taskDetailModel.test.ts`: a sub-task
/// placed only through its compound, and a counter root placed only through its
/// linked row, no longer read "Not on a board".
@MainActor
final class TaskDetailPlacementsTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let start = "2026-10-12T00:00:00.000Z", end = "2026-10-18T23:59:59.999Z"

    private func link(_ compound: String, _ child: String) -> CompoundChild {
        CompoundChild(
            id: "l-\(compound)-\(child)", compoundTaskId: compound, childTaskId: child, childIndex: 0,
            createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    func test_aSubTaskPlacedOnlyThroughItsCompound_getsThatBoard_scoredAsTheSubTask() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(K.task("s", maxCount: 3))
        var parent = K.task("P", maxCount: nil)
        parent.type = .compound
        parent.operatorType = .and
        try db.saveTask(parent)
        try db.write { try self.link("P", "s").save($0) }
        try db.saveBoard(K.board(id: "B", startDate: start, endDate: end, timeframe: .weekly))
        try db.saveBoardTask(K.placement(id: "btP", boardId: "B", taskId: "P"))
        try K.addIncrement(db, taskId: "s", delta: 2, occurredAt: "2026-10-14T10:00:00.000Z")

        let got = try db.fetchTaskDetailPlacements(taskId: "s")

        XCTAssertTrue(got.ownPlacements.isEmpty)
        XCTAssertEqual(got.boards.map(\.id), ["B"])
        XCTAssertEqual(got.rows.map(\.memberTaskId), ["s"])
        XCTAssertEqual(got.rows.first?.viaCompoundId, "P")
        XCTAssertEqual(got.rows.first?.count, 2)
        XCTAssertEqual(got.rows.first?.goal, 3)
        XCTAssertEqual(got.rows.first?.done, false)
    }

    /// Binding decision 3 (3): a direct Normal / Counting sub-task anchors on its
    /// compound's square; a sub-compound, or a deeper descendant, does not.
    func test_aDirectSubTaskAnchorsOnItsCompoundsSquare_aSubCompoundOrDeeperOneDoesNot() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        for id in ["P", "Q"] {
            var c = K.task(id, maxCount: nil)
            c.type = .compound
            c.operatorType = .and
            try db.saveTask(c)
        }
        try db.saveTask(K.task("n", maxCount: 3))
        try db.saveTask(K.task("m", maxCount: 3))
        try db.write { db in
            try self.link("P", "n").save(db)
            try self.link("P", "Q").save(db)
            try self.link("Q", "m").save(db)
        }
        try db.saveBoard(K.board(id: "B", startDate: start, endDate: end, timeframe: .weekly))
        try db.saveBoardTask(K.placement(id: "btP", boardId: "B", taskId: "P"))

        let n = try db.fetchTaskDetailPlacements(taskId: "n").anchorCandidates
        XCTAssertEqual(n.map(\.placement.id), ["btP"])
        XCTAssertEqual(n.map(\.childTaskId), ["n"])
        XCTAssertEqual(n.map(\.rank), [2])
        XCTAssertTrue(try db.fetchTaskDetailPlacements(taskId: "Q").anchorCandidates.isEmpty)
        XCTAssertTrue(try db.fetchTaskDetailPlacements(taskId: "m").anchorCandidates.isEmpty)
    }

    func test_aCounterRoot_reachesItsLinkedRowsBoard_andDeletedBoardsDropOut() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var root = K.task("r", maxCount: nil)
        root.isCounter = true
        try db.saveTask(root)
        try db.saveTask(K.task("l", maxCount: 5, sharedCounterId: "r", baseline: 0))
        try db.saveBoard(K.board(id: "B", startDate: start, endDate: end, timeframe: .weekly))
        var gone = K.board(id: "X", startDate: start, endDate: end, timeframe: .weekly)
        gone.isDeleted = true
        try db.saveBoard(gone)
        try db.saveBoardTask(K.placement(id: "bt1", boardId: "B", taskId: "l"))
        try db.saveBoardTask(K.placement(id: "bt2", boardId: "X", taskId: "l"))
        try K.addIncrement(db, taskId: "r", delta: 5, occurredAt: "2026-10-15T10:00:00.000Z")

        let got = try db.fetchTaskDetailPlacements(taskId: "r")

        XCTAssertTrue(got.ownPlacements.isEmpty)
        // The root's hero may anchor on its linked row's square (a log there writes the root).
        XCTAssertEqual(got.anchorCandidates.map(\.placement.id), ["bt1", "bt2"])
        XCTAssertEqual(got.anchorCandidates.map(\.rank), [1, 1])
        XCTAssertEqual(got.rows.map(\.boardId), ["B"])
        XCTAssertEqual(got.rows.first?.memberTaskId, "l")
        XCTAssertEqual(got.rows.first?.done, true)
    }
}
