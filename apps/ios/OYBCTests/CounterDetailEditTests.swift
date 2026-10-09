import XCTest
import GRDB
@testable import OYBC

/// Counter Detail "⋯" → Edit counter… (both platforms): the overflow lists
/// Edit above Delete only for a live root, and an edit of the root through
/// the global editor's write (`applyTaskEditPatch`) is what the page's reload
/// (`CounterDetailView.loadSnapshot`) shows. Web twin:
/// `components/counters/__tests__/counterDetailMenu.test.ts`.
@MainActor
final class CounterDetailEditTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let liveStart = "2026-10-05T00:00:00.000Z", liveEnd = "2099-12-31T23:59:59.999Z"

    private func seed(rootDeleted: Bool = false) throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var root = K.task("root", maxCount: nil, currentCount: 12, title: "Run miles")
        root.isCounter = true
        root.countKind = .discrete
        root.isDeleted = rootDeleted
        try db.saveTask(root)
        var copy = K.task("copy", maxCount: 10, sharedCounterId: "root", title: "Run 10 miles")
        copy.countKind = .discrete
        try db.saveTask(copy)
        try db.saveBoard(K.board(id: "b", startDate: liveStart, endDate: liveEnd, timeframe: .weekly))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b", taskId: "copy"))
        return db
    }

    private func load(_ db: AppDatabase) -> CounterDetailView.Snapshot {
        CounterDetailView.loadSnapshot(
            database: db, userId: K.userId, counterId: "root", showExpired: false,
            now: AppDatabase.currentTimestamp()
        )
    }

    func test_overflow_editAboveDelete_onlyWithALiveRoot() {
        XCTAssertEqual(CounterDetailContent.overflowItems(canEdit: true), [.edit, .delete])
        XCTAssertEqual(CounterDetailContent.overflowItems(canEdit: false), [.delete])
        XCTAssertEqual(CounterDetailContent.OverflowItem.edit.label, "Edit counter…")
        XCTAssertEqual(CounterDetailContent.OverflowItem.delete.label, "Delete counter…")
    }

    func test_loadSnapshot_exposesTheLiveRoot() throws {
        let snap = load(try seed())
        XCTAssertEqual(snap.root?.id, "root")
        XCTAssertEqual(snap.group?.counterId, "root")
    }

    func test_loadSnapshot_deletedRoot_hasNoEditableRoot() throws {
        XCTAssertNil(load(try seed(rootDeleted: true)).root)
    }

    func test_editRoot_kindAndTitle_reloadShowsThem_andTheCopyFollows() throws {
        let db = try seed()
        XCTAssertEqual(load(db).group?.countKind, .discrete)

        let patch = EditTaskSheet.Patch(
            title: "Jog miles", description: "", action: "Jog", unit: "miles", maxCountStr: "",
            trigger: .bingo, requiredCountStr: "", refMode: .board, selectedBoardId: "", selectedTemplateId: "",
            countKind: .continuous
        )
        try db.applyTaskEditPatch(taskId: "root", patch: patch)

        let snap = load(db)
        XCTAssertEqual(snap.group?.countKind, .continuous)
        XCTAssertEqual(snap.group?.action, "Jog")
        XCTAssertEqual(snap.root?.title, "Jog miles")
        XCTAssertEqual(try K.fetchTask(db, "copy")?.countKind, .continuous)
    }
}
