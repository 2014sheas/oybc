import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 1 (extended slice 3) — the staged per-square
/// lock through `BoardPlayViewModel`: toggle stages an override, counts as
/// one edit, marks the square dirty, pins the squares-edit grid cell, and
/// Save commits it inside the atomic transaction (`setBoardTaskLocked`).
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
        XCTAssertTrue(vm.editSquaresEditCells.first { $0.id == "bt1" }?.isDirty ?? false)
        XCTAssertEqual(vm.editSquaresDraft["0-0"]?.isLocked, true,
                       "the draft row carries the staged lock for the grid chip")

        // Toggling back to the stored value drops the override — derived count.
        vm.handleEditToggleLock(cellKey: "0-0")
        XCTAssertFalse(vm.isEditCellLocked(cellKey: "0-0"))
        XCTAssertEqual(vm.editSquaresEditCount, 0)
        XCTAssertFalse(vm.editSquaresEditCells.first { $0.id == "bt1" }?.isDirty ?? true)
    }

    func test_unlockStoredLock_countsOneEdit() throws {
        let db = try makeDb(); try seed(db)
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditToggleLock(cellKey: "0-1")
        XCTAssertFalse(vm.isEditCellLocked(cellKey: "0-1"))
        XCTAssertEqual(vm.editSquaresEditCount, 1)
    }

    func test_squaresEditCells_pinLockedSquares() throws {
        let db = try makeDb(); try seed(db)
        let vm = loadedVM(db)
        let board = try XCTUnwrap(vm.board)
        vm.seedEditDraft(from: board)

        let cells = vm.editSquaresEditCells
        XCTAssertEqual(cells.first { $0.id == "bt2" }?.isLocked, true, "stored lock pins")
        XCTAssertEqual(cells.first { $0.id == "bt1" }?.isLocked, false)
        XCTAssertTrue(cells.first { $0.id == "bt2" }?.isPinned ?? false)

        // A staged lock pins the (always freshly-derived, D20) grid immediately.
        vm.handleEditToggleLock(cellKey: "0-0")
        XCTAssertEqual(vm.editSquaresEditCells.first { $0.id == "bt1" }?.isLocked, true)
        XCTAssertTrue(vm.editSquaresEditCells.first { $0.id == "bt1" }?.isPinned ?? false)
    }

    /// D11 — a staged add's lock is written at insertion
    /// (`addBoardTaskToBoard(isLocked:)`), so it's never a separate
    /// "lock change" edit or DB write; only the ONE add edit counts.
    func test_lockAnAddedCell_isWrittenAtInsertion_notASeparateEdit() throws {
        let db = try makeDb(); try seed(db)
        try db.saveTask(makeTask("t3"))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditAdd(cellKey: "1-0", taskId: "t3")
        vm.handleEditToggleLock(cellKey: "1-0")
        XCTAssertTrue(vm.isEditCellLocked(cellKey: "1-0"))
        XCTAssertEqual(vm.editSquaresEditCount, 1, "the add is ONE edit; locking it isn't a second")

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let added = try XCTUnwrap(db.fetchBoardTasks(boardId: "b1").first { $0.taskId == "t3" })
        XCTAssertTrue(added.isLocked, "the staged lock was written by the add itself")
    }

    /// A legacy-CHOSEN board's center placement reads as locked WITHOUT any
    /// stored `isLocked` flag (D1's implicit lock). Unlocking it stages a
    /// real override, and Save both normalizes CHOSEN → NONE (D2) and
    /// writes `isLocked: false` on the (no-longer-center) placement.
    func test_unlockLegacyChosenCenter_normalizesOnSave() throws {
        let db = try makeDb()
        try seedUser(db)
        var board = makeBoard(id: "b1")
        board.centerSquareType = .chosen
        try db.saveBoard(board)
        try db.saveTask(makeTask("t1"))
        // 3×3 — the positional center is (1,1).
        try db.saveBoardTask(makeBoardTask(id: "bt1", taskId: "t1", row: 1, col: 1))

        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        XCTAssertEqual(vm.editCenterType, .none, "D1 — CHOSEN reads as the effective NONE")
        XCTAssertTrue(vm.isEditCellLocked(cellKey: "1-1"), "the implicit legacy-CHOSEN lock")

        vm.handleEditToggleLock(cellKey: "1-1")
        XCTAssertFalse(vm.isEditCellLocked(cellKey: "1-1"))
        XCTAssertEqual(vm.editSquaresEditCount, 1)

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(saved.centerSquareType, .none, "normalized on Save (D2)")
        XCTAssertNil(saved.centerTaskId)
        let center = try XCTUnwrap(db.fetchBoardTasks(boardId: "b1").first { $0.id == "bt1" })
        XCTAssertFalse(center.isLocked, "the staged unlock committed")
        XCTAssertFalse(center.isCenter)
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
        XCTAssertEqual(vm.editSquaresDraft["0-0"]?.isLocked, false, "re-seeded to the stored value")
    }
}
