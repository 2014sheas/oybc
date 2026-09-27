import XCTest
@testable import OYBC

/// Regression tests for `BoardWizardViewModel.updateSize` center-square
/// coercion.
///
/// The bug: `updateSize` coerced a NONE center to FREE whenever the new
/// size was odd AND the current center was NONE — but it fired on *every*
/// odd-size selection, not just the even→odd crossing. So a user who
/// deliberately picked "None" on an odd board, then re-touched the size
/// card (even re-selecting the same size) while paging back and forth in
/// the wizard, silently got a FREE center on the created board.
///
/// The fix only coerces NONE→FREE when actually crossing from an even
/// board (which forces NONE) to an odd one. These tests pin that contract.
final class BoardWizardCenterSquareTests: XCTestCase {

    private func makeVM() -> BoardWizardViewModel {
        BoardWizardViewModel(preferences: UserPreferences.defaults)
    }

    /// Re-selecting the same — or another — ODD size must preserve a
    /// deliberate NONE center. This is the exact regression the user hit.
    func testOddToOddReselectPreservesNoneCenter() {
        let vm = makeVM()
        vm.updateSize(5)            // odd
        vm.updateCenterType(.none)  // user deliberately chooses "None"
        XCTAssertEqual(vm.centerType, .none)

        vm.updateSize(5)            // re-tap the SAME odd size
        XCTAssertEqual(
            vm.centerType, .none,
            "Re-tapping the same odd size must not revert None→Free"
        )

        vm.updateSize(3)            // switch to ANOTHER odd size
        XCTAssertEqual(
            vm.centerType, .none,
            "Switching odd→odd must not revert None→Free"
        )
    }

    /// Crossing EVEN→ODD should give the (otherwise hidden) center a
    /// visible FREE default, since the even board had forced NONE.
    func testEvenToOddCoercesNoneToFree() {
        let vm = makeVM()
        vm.updateSize(4)            // even forces NONE
        XCTAssertEqual(vm.centerType, .none)

        vm.updateSize(5)            // even→odd crossing
        XCTAssertEqual(
            vm.centerType, .free,
            "Crossing even→odd should default a forced None to Free"
        )
    }

    /// A non-NONE odd center is preserved across an odd→odd size change.
    func testOddToOddPreservesChosenCenter() {
        let vm = makeVM()
        vm.updateSize(5)
        vm.updateCenterType(.chosen)
        vm.setCenterTaskId("task-123")

        vm.updateSize(3)            // odd→odd
        XCTAssertEqual(vm.centerType, .chosen)
        XCTAssertEqual(vm.centerTaskId, "task-123")
    }

    /// Switching to an EVEN size always forces NONE and clears any chosen
    /// center task (even boards have no center concept).
    func testEvenForcesNoneAndClearsChosenTask() {
        let vm = makeVM()
        vm.updateSize(5)
        vm.updateCenterType(.chosen)
        vm.setCenterTaskId("task-123")

        vm.updateSize(4)            // even
        XCTAssertEqual(vm.centerType, .none)
        XCTAssertNil(
            vm.centerTaskId,
            "Even boards have no center; chosen task id must clear"
        )
    }

    // MARK: - Persisted BoardTask.isCenter (bugfix/ios-wizard-draft-leakage)
    //
    // The bug: `persistWizardBoard` set `isCenter` for `.none` centers too,
    // so the play grid rendered a gold "FREE" cell over a real task (the
    // preview never did — it gates on `centerType != .none`). These pin the
    // shared `makeWizardBoardTaskRows` helper both the wizard and recurring
    // spawn use.

    private func t(_ id: String) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: "u1", title: "T\(id)", type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: "2026-07-01T12:00:00.000", updatedAt: "2026-07-01T12:00:00.000",
            version: 1, isDeleted: false, createdInWizard: false
        )
    }

    /// 3×3 placement with a real task in every cell (center = index 4).
    private func full3x3() -> WizardPlacement { (0..<9).map { i -> OYBC.Task? in t("t\(i)") } }

    func testPersistedCenterFlaggedOnlyForChosen() {
        let now = "2026-07-01T12:00:00.000"

        let chosen = makeWizardBoardTaskRows(placement: full3x3(), boardId: "b", size: 3, centerType: .chosen, now: now)
        XCTAssertEqual(chosen.count, 9)
        XCTAssertTrue(chosen.first { $0.row == 1 && $0.col == 1 }!.isCenter,
                      "A CHOSEN center task must be flagged isCenter")
        XCTAssertEqual(chosen.filter { $0.isCenter }.count, 1)

        let none = makeWizardBoardTaskRows(placement: full3x3(), boardId: "b", size: 3, centerType: .none, now: now)
        XCTAssertFalse(none.first { $0.row == 1 && $0.col == 1 }!.isCenter,
                       "A NONE center holds an ordinary task and must NOT be isCenter (was rendering a FREE cell)")
        XCTAssertEqual(none.filter { $0.isCenter }.count, 0)
    }

    func testPersistedFreeCenterHasNoRow() {
        // FREE reserves the center as a nil slot → no BoardTask row,
        // and nothing is flagged isCenter (the play grid renders FREE positionally).
        var p = full3x3()
        p[4] = nil
        let rows = makeWizardBoardTaskRows(placement: p, boardId: "b", size: 3, centerType: .free, now: "n")
        XCTAssertEqual(rows.count, 8)
        XCTAssertFalse(rows.contains { $0.row == 1 && $0.col == 1 }, "No row at the reserved FREE center")
        XCTAssertEqual(rows.filter { $0.isCenter }.count, 0)
    }

    // MARK: - Board Edit slice 3 (D4): active persist translates CHOSEN

    func testRowBuilder_translatesChosenToLockedTaskSquare_whenRequested() {
        let rows = makeWizardBoardTaskRows(
            placement: full3x3(), boardId: "b", size: 3, centerType: .chosen,
            translateChosenToLock: true, now: "n"
        )
        let center = rows.first { $0.row == 1 && $0.col == 1 }!
        XCTAssertFalse(center.isCenter, "a translated CHOSEN center is an ordinary task square")
        XCTAssertTrue(center.isLocked, "…pinned by a lock instead")
        XCTAssertEqual(rows.filter { $0.isLocked }.count, 1, "only the center is locked")
        XCTAssertEqual(rows.filter { $0.isCenter }.count, 0)
    }

    func testRowBuilder_translationIsInertForFreeAndNone() {
        for type in [CenterSquareType.none, .free] {
            var p = full3x3()
            if type == .free { p[4] = nil }
            let rows = makeWizardBoardTaskRows(
                placement: p, boardId: "b", size: 3, centerType: type,
                translateChosenToLock: true, now: "n"
            )
            XCTAssertEqual(rows.filter { $0.isLocked || $0.isCenter }.count, 0, "\(type)")
        }
    }

    private func seedUserAndTasks(_ db: AppDatabase, userId: String, count: Int) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "\(userId)@example.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        for i in 0..<count {
            var task = t("t\(i)")
            task.userId = userId
            try db.saveTask(task)
        }
    }

    private func persist(_ vm: BoardWizardViewModel, userId: String, status: WizardStatus) throws -> String {
        let expectation = XCTestExpectation(description: "persistWizardBoard")
        var resultId: String?
        var errorMessage: String?
        persistWizardBoard(
            controller: vm, userId: userId, placement: full3x3(),
            dates: (start: "2026-07-01T00:00:00.000", end: "2026-07-01T23:59:59.999"),
            status: status, database: vm.database,
            onSuccess: { id in resultId = id; expectation.fulfill() },
            onError: { msg in errorMessage = msg; expectation.fulfill() }
        )
        wait(for: [expectation], timeout: 5.0)
        XCTAssertNil(errorMessage)
        return try XCTUnwrap(resultId)
    }

    private func chosenWizard(_ db: AppDatabase, userId: String) -> BoardWizardViewModel {
        let vm = BoardWizardViewModel(preferences: .defaults, userId: userId, database: db)
        vm.name = "Chosen"
        vm.updateSize(3)
        vm.updateCenterType(.chosen)
        vm.centerTaskId = "t4"
        vm.isRandomized = false
        return vm
    }

    func testActivePersist_chosenPick_writesNoneBoard_andLockedCenterPlacement() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUserAndTasks(db, userId: "u1", count: 9)
        let boardId = try persist(chosenWizard(db, userId: "u1"), userId: "u1", status: .active)

        let board = try XCTUnwrap(db.fetchBoard(id: boardId))
        XCTAssertEqual(board.centerSquareType, .none, "no new live board is CHOSEN")
        XCTAssertNil(board.centerTaskId)
        let rows = try db.fetchBoardTasks(boardId: boardId)
        let center = try XCTUnwrap(rows.first { $0.row == 1 && $0.col == 1 })
        XCTAssertEqual(center.taskId, "t4")
        XCTAssertTrue(center.isLocked)
        XCTAssertFalse(center.isCenter)
        XCTAssertEqual(rows.filter { $0.isLocked }.count, 1)
    }

    func testDraftPersist_chosenPick_keepsChosenAndCenterTaskId() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUserAndTasks(db, userId: "u1", count: 9)
        let boardId = try persist(chosenWizard(db, userId: "u1"), userId: "u1", status: .draft)

        let board = try XCTUnwrap(db.fetchBoard(id: boardId))
        XCTAssertEqual(board.centerSquareType, .chosen, "drafts keep CHOSEN so resume restores the pick")
        XCTAssertEqual(board.centerTaskId, "t4")
        let center = try XCTUnwrap(db.fetchBoardTasks(boardId: boardId).first { $0.row == 1 && $0.col == 1 })
        XCTAssertTrue(center.isCenter)
        XCTAssertFalse(center.isLocked)
    }
}
