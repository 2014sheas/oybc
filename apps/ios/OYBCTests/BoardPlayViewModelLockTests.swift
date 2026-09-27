import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 1 — the staged per-square lock through
/// `BoardPlayViewModel`: toggle stages an override, counts as one edit, marks
/// the square dirty, pins the Rearrange cell, and Save commits it inside the
/// atomic transaction (`setBoardTaskLocked`).
@MainActor
final class BoardPlayViewModelLockTests: XCTestCase {

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: "u1", email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeBoard(id: String) -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": "u1", "name": "Board \(id)", "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-21T00:00:00.000",
            "centerSquareType": CenterSquareType.free.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-06-21T00:00:00.000", "updatedAt": "2026-06-21T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeTask(_ id: String) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: "u1", title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil,
            requiredCount: nil, totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
    }

    private func makeBoardTask(id: String, taskId: String, row: Int, col: Int, isLocked: Bool = false) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: "b1", taskId: taskId, row: row, col: col, isCenter: false,
            isLocked: isLocked, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    /// b1: t1@(0,0) bt1, t2@(0,1) bt2 (already locked).
    private func seed(_ db: AppDatabase) throws {
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", taskId: "t1", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt2", taskId: "t2", row: 0, col: 1, isLocked: true))
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    private func loadedVM(_ db: AppDatabase) -> BoardPlayViewModel {
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()
        _ = waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty }
        return vm
    }

    func test_toggleLock_stagesOverride_countsOneEdit_marksDirty() throws {
        let db = try makeDb(); try seed(db)
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        XCTAssertFalse(vm.isEditCellLocked(cellKey: "0-0"))
        XCTAssertTrue(vm.isEditCellLocked(cellKey: "0-1"), "stored lock reads through")
        XCTAssertEqual(vm.editSquaresEditCount, 0)

        vm.handleEditToggleLock(cellKey: "0-0")
        XCTAssertTrue(vm.isEditCellLocked(cellKey: "0-0"))
        XCTAssertEqual(vm.editSquaresEditCount, 1)
        XCTAssertTrue(vm.editDirtyCellKeys.contains("0-0"))
        XCTAssertEqual(vm.editDraftBoardTasks.first { $0.id == "bt1" }?.isLocked, true,
                       "the draft row carries the staged lock for the grid chip")

        // Toggling back to the stored value drops the override — derived count.
        vm.handleEditToggleLock(cellKey: "0-0")
        XCTAssertFalse(vm.isEditCellLocked(cellKey: "0-0"))
        XCTAssertEqual(vm.editSquaresEditCount, 0)
        XCTAssertFalse(vm.editDirtyCellKeys.contains("0-0"))
    }

    func test_unlockStoredLock_countsOneEdit() throws {
        let db = try makeDb(); try seed(db)
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditToggleLock(cellKey: "0-1")
        XCTAssertFalse(vm.isEditCellLocked(cellKey: "0-1"))
        XCTAssertEqual(vm.editSquaresEditCount, 1)
    }

    func test_rearrangeCells_pinLockedSquares() throws {
        let db = try makeDb(); try seed(db)
        let vm = loadedVM(db)
        let board = try XCTUnwrap(vm.board)
        vm.seedEditDraft(from: board)
        vm.seedRearrangeCells(for: board)

        let cells = try XCTUnwrap(vm.editRearrangeCells)
        XCTAssertEqual(cells.first { $0.id == "bt2" }?.isLocked, true, "stored lock pins")
        XCTAssertEqual(cells.first { $0.id == "bt1" }?.isLocked, false)

        // A staged lock pins an already-seeded grid immediately.
        vm.handleEditToggleLock(cellKey: "0-0")
        XCTAssertEqual(vm.editRearrangeCells?.first { $0.id == "bt1" }?.isLocked, true)
        XCTAssertTrue(vm.editRearrangeCells?.first { $0.id == "bt1" }?.isPinned ?? false)
    }

    func test_handleEditSave_commitsLockChanges_inOneTransaction() throws {
        let db = try makeDb(); try seed(db)
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditToggleLock(cellKey: "0-0")   // lock bt1
        vm.handleEditToggleLock(cellKey: "0-1")   // unlock bt2
        XCTAssertEqual(vm.editSquaresEditCount, 2)

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved }, "never emitted .saved")

        let rows = try db.fetchBoardTasks(boardId: "b1")
        XCTAssertEqual(rows.first { $0.id == "bt1" }?.isLocked, true)
        XCTAssertEqual(rows.first { $0.id == "bt2" }?.isLocked, false)
        XCTAssertEqual(rows.first { $0.id == "bt1" }?.version, 2)
        XCTAssertEqual(rows.first { $0.id == "bt2" }?.version, 2)
    }

    func test_reseed_dropsStagedLocks() throws {
        let db = try makeDb(); try seed(db)
        let vm = loadedVM(db)
        let board = try XCTUnwrap(vm.board)
        vm.seedEditDraft(from: board)
        vm.handleEditToggleLock(cellKey: "0-0")
        XCTAssertEqual(vm.editSquaresEditCount, 1)

        vm.seedEditDraft(from: board)
        XCTAssertEqual(vm.editSquaresEditCount, 0)
        XCTAssertTrue(vm.editLockOverrides.isEmpty)
    }
}
