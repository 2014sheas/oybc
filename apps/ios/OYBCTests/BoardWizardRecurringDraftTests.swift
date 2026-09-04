import XCTest
@testable import OYBC

/// Board Creation Split (iOS PR B) — recurring drafts.
///
/// Recurring boards used to commit immediately (no draft state); PR B
/// reuses the existing DRAFT-`Board` path so a recurring board can be
/// saved as a draft exactly like a one-off one. This file covers:
///
///  1. Save-as-draft → resume → Create Board round-trip: the FULL pool mix
///     (including overfill beyond the grid size) survives via
///     `Board.recurringDraftMix`, never the (possibly truncated) placed
///     `BoardTask` rows — and creating the board tombstones the original
///     draft `Board` row.
///  2. `Board`/`RecurringDraftMixPayload` Codable round-trips + forward
///     compatibility (mirrors `isCore`'s decode-as-false-when-absent
///     posture).
///  3. `DraftRowData.kind` discrimination.
///  4. `BoardWizardViewModel.resolveDraftInitialStep` — Setup / Pool /
///     Preview resume-step selection for both one-off and recurring
///     drafts.
///
/// ── AppDatabase.shared, not makeTestInstance() (round-trip tests only) ──
/// `persistWizardBoard` / `persistRecurringTemplate` are free functions
/// that reach for `AppDatabase.shared` directly (no injectable-database
/// seam), matching `BoardWizardPersistRecurringTemplateTests`'s existing
/// posture. Every test uses a fresh `UUID()`-derived `userId` + matching
/// real `User`/`Task` rows and hard-deletes everything it created in a
/// `defer` block. The pure `resolveDraftInitialStep` tests use an isolated
/// `AppDatabase.makeTestInstance()` instead, since that function IS
/// database-injectable.
final class BoardWizardRecurringDraftTests: XCTestCase {

    // MARK: - Fixtures (AppDatabase.shared round-trip tests)

    private func seedUser(_ userId: String) throws {
        let now = AppDatabase.currentTimestamp()
        try AppDatabase.shared.saveUser(User(
            id: userId,
            email: "\(userId)@example.com",
            displayName: "Test User",
            photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1
        ))
    }

    private func seedTask(_ id: String, userId: String) throws {
        let now = AppDatabase.currentTimestamp()
        try AppDatabase.shared.saveTask(Task(
            id: id, userId: userId, title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        ))
    }

    private func cleanup(
        poolIds: [String] = [],
        templateIds: [String] = [],
        boardIds: [String] = [],
        taskIds: [String] = [],
        userIds: [String] = []
    ) {
        try? AppDatabase.shared.write { db in
            for id in boardIds {
                try db.execute(sql: "DELETE FROM board_tasks WHERE boardId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM boards WHERE id = ?", arguments: [id])
            }
            for id in templateIds {
                try db.execute(sql: "DELETE FROM recurring_board_templates WHERE id = ?", arguments: [id])
            }
            for id in poolIds {
                try db.execute(sql: "DELETE FROM pools WHERE id = ?", arguments: [id])
            }
            for id in taskIds {
                try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [id])
            }
            for id in userIds {
                try db.execute(sql: "DELETE FROM users WHERE id = ?", arguments: [id])
            }
            for id in poolIds + templateIds + boardIds {
                try db.execute(sql: "DELETE FROM sync_queue WHERE entityId = ?", arguments: [id])
            }
        }
    }

    /// Runs `persistWizardBoard` synchronously, returning the boardId or
    /// failing the test on an unexpected error.
    private func runPersistWizardBoard(
        controller: BoardWizardViewModel,
        userId: String,
        placement: WizardPlacement,
        dates: (start: String, end: String?),
        status: WizardStatus
    ) throws -> String {
        let expectation = XCTestExpectation(description: "persistWizardBoard")
        var resultBoardId: String?
        var errorMessage: String?
        persistWizardBoard(
            controller: controller, userId: userId, placement: placement, dates: dates, status: status,
            onSuccess: { boardId in resultBoardId = boardId; expectation.fulfill() },
            onError: { message in errorMessage = message; expectation.fulfill() }
        )
        wait(for: [expectation], timeout: 5.0)
        XCTAssertNil(errorMessage)
        return try XCTUnwrap(resultBoardId)
    }

    /// Runs `persistRecurringTemplate` synchronously (mirrors
    /// `BoardWizardPersistRecurringTemplateTests.runPersist`).
    private func runPersistRecurringTemplate(
        controller: BoardWizardViewModel, userId: String
    ) throws -> RecurringTemplatePersistOutcome {
        let expectation = XCTestExpectation(description: "persistRecurringTemplate")
        var outcome: RecurringTemplatePersistOutcome?
        var errorMessage: String?
        persistRecurringTemplate(
            controller: controller, userId: userId,
            onSuccess: { result in outcome = result; expectation.fulfill() },
            onError: { message in errorMessage = message; expectation.fulfill() }
        )
        wait(for: [expectation], timeout: 5.0)
        XCTAssertNil(errorMessage)
        return try XCTUnwrap(outcome)
    }

    // MARK: - 1. Save-as-draft → resume → Create Board round-trip

    /// The load-bearing regression this feature exists to prevent: a
    /// recurring pool that OVERFILLS its grid (6 selected tasks on a 2×2
    /// board that only needs 4) must survive a save/resume round-trip in
    /// full — never truncated to the 4 tasks that actually got placed as
    /// `BoardTask` rows. Also exercises "convert draft → template on
    /// Create Board": the resumed draft's cadence + FULL mix (pool +
    /// manual layer) must land on the created `RecurringBoardTemplate`,
    /// and the original placeholder draft `Board` must be tombstoned.
    func test_recurringDraft_saveResumeCreate_preservesFullOverfilledMix_andRetiresDraft() throws {
        let userId = "test-user-\(UUID().uuidString)"
        let poolTaskIds = ["p1", "p2", "p3"]
        let manualTaskIds = ["m1", "m2", "m3"]
        let allTaskIds = poolTaskIds + manualTaskIds
        try seedUser(userId)
        for id in allTaskIds { try seedTask(id, userId: userId) }

        var draftBoardId: String?
        var templateId: String?
        var spawnedBoardId: String?
        var poolId: String?
        defer {
            cleanup(
                poolIds: poolId.map { [$0] } ?? [],
                templateIds: templateId.map { [$0] } ?? [],
                boardIds: [draftBoardId, spawnedBoardId].compactMap { $0 },
                taskIds: allTaskIds,
                userIds: [userId]
            )
        }

        let now = AppDatabase.currentTimestamp()
        let pool = try AppDatabase.shared.createPoolAndEnqueue(
            userId: userId, name: "Pool P", taskIds: poolTaskIds, now: now
        )
        poolId = pool.id

        // ── Step A: build + save a fresh recurring draft ────────────────
        let vm = BoardWizardViewModel(preferences: .defaults, startRecurring: true, userId: userId, database: AppDatabase.shared)
        vm.name = "Overfilled Weekly"
        vm.size = 2 // 2x2, centerType .none => tasksRequired = 4
        vm.centerType = .none
        vm.updateTimeframe(.weekly)
        // Deterministic placement so the truncation assertion below is stable.
        vm.isRandomized = false

        let tasksById = Dictionary(
            uniqueKeysWithValues: try allTaskIds.map { id -> (String, Task) in
                (id, try XCTUnwrap(AppDatabase.shared.fetchTask(id: id)))
            }
        )
        vm.pullPool(pool, tasksById: tasksById)
        XCTAssertEqual(vm.selectedTaskIds, Set(poolTaskIds))
        for id in manualTaskIds { vm.toggleTaskSelection(id) }
        XCTAssertEqual(vm.selectedTaskIds.count, 6, "3 pool + 3 manual = 6, overfilling the 4-cell grid")
        XCTAssertEqual(vm.tasksRequired, 4)

        let library = TaskLibraryViewModel()
        library.libraryTasks = allTaskIds.map { tasksById[$0]! }
        let placement = buildWizardPlacement(controller: vm, library: library)

        guard case .ok(let start, let end) = resolveWizardDates(controller: vm) else {
            XCTFail("expected resolvable dates")
            return
        }

        draftBoardId = try runPersistWizardBoard(
            controller: vm, userId: userId, placement: placement, dates: (start, end), status: .draft
        )
        let savedDraftBoardId = try XCTUnwrap(draftBoardId)

        // The placed BoardTask rows are truncated to the grid size — this
        // is the exact truncation the mix snapshot must route around.
        let placedRows = try AppDatabase.shared.fetchBoardTasks(boardId: savedDraftBoardId)
        XCTAssertEqual(placedRows.count, 4, "only 4 of the 6 selected tasks fit the 2x2 grid")

        let savedBoard = try XCTUnwrap(AppDatabase.shared.fetchBoard(id: savedDraftBoardId))
        XCTAssertEqual(savedBoard.status, .draft)
        XCTAssertTrue(savedBoard.isRecurringDraft)
        XCTAssertEqual(savedBoard.timeframe, .weekly)
        let savedMix = RecurringDraftMixPayload.decoded(from: savedBoard.recurringDraftMix)
        XCTAssertEqual(savedMix.poolIds, [pool.id])
        XCTAssertEqual(Set(savedMix.manualTaskIds), Set(manualTaskIds))
        XCTAssertEqual(savedMix.removedTaskIds, [])

        // ── Step B: resume — the FULL 6-task mix must come back, not the
        // truncated 4-row placement. ─────────────────────────────────────
        let resumedVM = BoardWizardViewModel(
            preferences: .defaults,
            draft: (savedBoard, placedRows),
            userId: userId,
            database: AppDatabase.shared
        )
        XCTAssertTrue(resumedVM.isRecurring, "a recurring draft must resume into recurring mode")
        XCTAssertEqual(resumedVM.timeframe, .weekly)
        XCTAssertEqual(
            resumedVM.selectedTaskIds, Set(allTaskIds),
            "the full overfilled pool must survive resume via recurringDraftMix"
        )
        XCTAssertEqual(resumedVM.pulledPoolIds, [pool.id])
        XCTAssertEqual(resumedVM.manualTaskIds, Set(manualTaskIds))
        XCTAssertTrue(resumedVM.removedTaskIds.isEmpty)

        // ── Step C: Create Board — converts the draft into a real
        // template + spawns the current window, then tombstones the
        // original draft Board. ─────────────────────────────────────────
        let outcome = try runPersistRecurringTemplate(controller: resumedVM, userId: userId)
        switch outcome {
        case .createdAndSpawned(let tId, let bId):
            templateId = tId
            spawnedBoardId = bId
        case .createdSpawnSkipped(let tId, let reason):
            templateId = tId
            XCTFail("expected a successful spawn, got skip reason \(reason)")
        case .updated:
            XCTFail("expected a fresh-create outcome, got .updated")
        }
        let createdTemplateId = try XCTUnwrap(templateId)

        let template = try XCTUnwrap(AppDatabase.shared.fetchRecurringBoardTemplate(id: createdTemplateId))
        XCTAssertEqual(template.timeframe, .weekly)
        XCTAssertEqual(template.poolIds, [pool.id])
        XCTAssertEqual(Set(template.manualTaskIds ?? []), Set(manualTaskIds))

        let retiredDraft = try XCTUnwrap(AppDatabase.shared.fetchBoard(id: savedDraftBoardId))
        XCTAssertTrue(retiredDraft.isDeleted, "the placeholder draft must be tombstoned once converted")
        XCTAssertNotNil(retiredDraft.deletedAt)
    }

    // MARK: - 2. Board / RecurringDraftMixPayload Codable

    /// Forward-compat: a Board row/doc written before this feature shipped
    /// (missing both keys) decodes as a plain one-off draft — mirrors
    /// `isCore`'s decode-as-false posture exactly.
    func test_board_decodesForwardCompatible_whenFieldsAbsent() throws {
        let dict: [String: Any] = [
            "id": "b1", "userId": "u1", "name": "Old Draft", "status": "draft",
            "boardSize": 3, "timeframe": "weekly", "startDate": "2026-01-01T00:00:00.000",
            "centerSquareType": "free", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-01-01T00:00:00.000", "updatedAt": "2026-01-01T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let board = try JSONDecoder().decode(Board.self, from: data)
        XCTAssertFalse(board.isRecurringDraft)
        XCTAssertNil(board.recurringDraftMix)
    }

    /// Round-trip: encoding then decoding a recurring-draft Board preserves
    /// both fields exactly.
    func test_board_encodeDecodeRoundTrip_recurringDraftFields() throws {
        var dict: [String: Any] = [
            "id": "b2", "userId": "u1", "name": "Recurring Draft", "status": "draft",
            "boardSize": 5, "timeframe": "monthly", "startDate": "2026-01-01T00:00:00.000",
            "centerSquareType": "none", "isRandomized": true,
            "totalTasks": 25, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-01-01T00:00:00.000", "updatedAt": "2026-01-01T00:00:00.000",
            "version": 1, "isDeleted": false,
            "isRecurringDraft": true,
        ]
        let mix = RecurringDraftMixPayload(poolIds: ["p1"], manualTaskIds: ["m1", "m2"], removedTaskIds: ["r1"])
        dict["recurringDraftMix"] = try XCTUnwrap(mix.encoded())

        let data = try JSONSerialization.data(withJSONObject: dict)
        let board = try JSONDecoder().decode(Board.self, from: data)
        XCTAssertTrue(board.isRecurringDraft)

        let reEncoded = try JSONEncoder().encode(board)
        let roundTripped = try JSONDecoder().decode(Board.self, from: reEncoded)
        XCTAssertTrue(roundTripped.isRecurringDraft)
        let roundTrippedMix = RecurringDraftMixPayload.decoded(from: roundTripped.recurringDraftMix)
        XCTAssertEqual(roundTrippedMix.poolIds, ["p1"])
        XCTAssertEqual(roundTrippedMix.manualTaskIds, ["m1", "m2"])
        XCTAssertEqual(roundTrippedMix.removedTaskIds, ["r1"])
    }

    /// A missing/malformed `recurringDraftMix` string decodes as an
    /// all-empty mix, never a crash or nil-payload — hydration always has
    /// a well-formed shape to resolve against.
    func test_recurringDraftMixPayload_decoded_fallsBackToEmpty_onMalformedOrMissing() {
        let missing = RecurringDraftMixPayload.decoded(from: nil)
        XCTAssertEqual(missing.poolIds, [])
        XCTAssertEqual(missing.manualTaskIds, [])
        XCTAssertEqual(missing.removedTaskIds, [])

        let malformed = RecurringDraftMixPayload.decoded(from: "not json")
        XCTAssertEqual(malformed.poolIds, [])
        XCTAssertEqual(malformed.manualTaskIds, [])
        XCTAssertEqual(malformed.removedTaskIds, [])
    }

    // MARK: - 3. DraftRowData.kind discrimination

    private func makeBoardFixture(isRecurringDraft: Bool) throws -> Board {
        let dict: [String: Any] = [
            "id": UUID().uuidString, "userId": "u1", "name": "Draft", "status": "draft",
            "boardSize": 3, "timeframe": "weekly", "startDate": "2026-01-01T00:00:00.000",
            "centerSquareType": "free", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-01-01T00:00:00.000", "updatedAt": "2026-01-01T00:00:00.000",
            "version": 1, "isDeleted": false,
            "isRecurringDraft": isRecurringDraft,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(Board.self, from: data)
    }

    func test_draftRowData_kind_matchesBoardIsRecurringDraft() throws {
        let oneOffBoard = try makeBoardFixture(isRecurringDraft: false)
        let recurringBoard = try makeBoardFixture(isRecurringDraft: true)

        let oneOffRow = DraftRowData(board: oneOffBoard, taskCount: 9)
        let recurringRow = DraftRowData(board: recurringBoard, taskCount: 12)

        XCTAssertEqual(oneOffRow.kind, .oneOff)
        XCTAssertEqual(recurringRow.kind, .recurring)
    }

    // MARK: - 4. resolveDraftInitialStep

    private func makeBoardTaskFixture(boardId: String, taskId: String, row: Int, col: Int) -> BoardTask {
        BoardTask(
            id: "bt-\(boardId)-\(row)-\(col)", boardId: boardId, taskId: taskId,
            row: row, col: col, isCenter: false,
            createdAt: "2026-01-01T00:00:00.000", updatedAt: "2026-01-01T00:00:00.000", version: 1
        )
    }

    func test_resolveDraftInitialStep_oneOff_setupTasksPreview() throws {
        let db = try AppDatabase.makeTestInstance()
        // 3x3, FREE center => tasksRequired = 8.
        let board = try makeBoardFixture(isRecurringDraft: false)

        let noTasks = BoardWizardViewModel.resolveDraftInitialStep(board: board, boardTasks: [], database: db)
        XCTAssertEqual(noTasks, 1, "no tasks selected yet => Setup")

        let someTasks = (0..<5).map { makeBoardTaskFixture(boardId: board.id, taskId: "t\($0)", row: $0 / 3, col: $0 % 3) }
        let below = BoardWizardViewModel.resolveDraftInitialStep(board: board, boardTasks: someTasks, database: db)
        XCTAssertEqual(below, 2, "below the 8-task requirement => Tasks")

        let fullTasks = (0..<8).map { makeBoardTaskFixture(boardId: board.id, taskId: "t\($0)", row: $0 / 3, col: $0 % 3) }
        let atFloor = BoardWizardViewModel.resolveDraftInitialStep(board: board, boardTasks: fullTasks, database: db)
        XCTAssertEqual(atFloor, 3, "at the requirement => Preview")
    }

    func test_resolveDraftInitialStep_recurring_readsFromMix_notPlacedRows() throws {
        let db = try AppDatabase.makeTestInstance()

        func recurringBoard(manualTaskIds: [String]) throws -> Board {
            var dict: [String: Any] = [
                "id": UUID().uuidString, "userId": "u1", "name": "Recurring Draft", "status": "draft",
                "boardSize": 2, "timeframe": "daily", "startDate": "2026-01-01T00:00:00.000",
                "centerSquareType": "none", "isRandomized": true,
                "totalTasks": 4, "completedTasks": 0, "linesCompleted": 0,
                "createdAt": "2026-01-01T00:00:00.000", "updatedAt": "2026-01-01T00:00:00.000",
                "version": 1, "isDeleted": false,
                "isRecurringDraft": true,
            ]
            let mix = RecurringDraftMixPayload(poolIds: [], manualTaskIds: manualTaskIds, removedTaskIds: [])
            dict["recurringDraftMix"] = try XCTUnwrap(mix.encoded())
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(Board.self, from: data)
        }

        // 2x2, NONE center => tasksRequired = 4. A one-off would count
        // `boardTasks` (empty here, deliberately, to prove the recurring
        // branch ignores it) — the recurring branch must read the mix.
        let emptyMixBoard = try recurringBoard(manualTaskIds: [])
        XCTAssertEqual(
            BoardWizardViewModel.resolveDraftInitialStep(board: emptyMixBoard, boardTasks: [], database: db), 1
        )

        let belowFloorBoard = try recurringBoard(manualTaskIds: ["m1", "m2"])
        XCTAssertEqual(
            BoardWizardViewModel.resolveDraftInitialStep(board: belowFloorBoard, boardTasks: [], database: db), 2
        )

        let atFloorBoard = try recurringBoard(manualTaskIds: ["m1", "m2", "m3", "m4"])
        // Even if `boardTasks` were the (truncated) placed rows, the
        // recurring branch must resolve against the mix, not this count.
        let truncatedPlacedRows = [makeBoardTaskFixture(boardId: atFloorBoard.id, taskId: "m1", row: 0, col: 0)]
        XCTAssertEqual(
            BoardWizardViewModel.resolveDraftInitialStep(board: atFloorBoard, boardTasks: truncatedPlacedRows, database: db),
            3,
            "recurring resume-step must derive from the full mix (4), not the 1 truncated placed row"
        )
    }
}
