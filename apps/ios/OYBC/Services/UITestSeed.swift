import Foundation

#if DEBUG
/// DEBUG-only seeding hook for the `OYBCUITests` XCUITest target.
///
/// Launched with `-bypassAuth YES -uiTestSeedEditBoard YES`, the debug auth
/// bypass (`AuthService.setupDebugBypass`) calls `seedIfRequested(userId:)`
/// after the playground user row exists. It upserts one deterministic 3×3
/// custom board — eight tasks "Alpha"…"Theta" in reading order around a FREE
/// center, with "Theta" (bottom-right) LOCKED — and then buffers a deep link
/// to it on `NotificationDelegate.shared` so `MainTabView` opens it on first
/// appear (the same path a notification tap uses). Fixed ids make every run
/// idempotent: re-seeding overwrites the rows in place.
///
/// Never compiled into Release builds; a no-op without the launch argument.
enum UITestSeed {

    /// Launch argument that turns the seed on.
    static let seedEditBoardArgument = "-uiTestSeedEditBoard"

    /// Id of the seeded board.
    static let boardId = "uitest-edit-board"

    /// Seeds the edit-mode fixture board when the launch argument is present.
    ///
    /// - Parameter userId: The bypass user's id (owner of every seeded row).
    /// - Throws: Any GRDB write error.
    @MainActor
    static func seedIfRequested(userId: String) throws {
        guard ProcessInfo.processInfo.arguments.contains(seedEditBoardArgument) else { return }
        let db = AppDatabase.shared
        let now = AppDatabase.currentTimestamp()

        try db.saveBoard(makeBoard(userId: userId, now: now))

        try seedTasks(boardId: boardId, taskIdPrefix: "uitest-task-",
                      boardTaskIdPrefix: "uitest-bt-", lockedTitle: "Theta",
                      userId: userId, now: now)

        NotificationDelegate.shared.pendingDeepLink = NotificationDeepLink(boardId: boardId)
    }

    /// An active custom 3×3 board with a FREE center.
    private static func makeBoard(userId: String, now: String) throws -> Board {
        let dict: [String: Any] = [
            "id": boardId, "userId": userId, "name": "UI Test Board",
            "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": Timeframe.custom.rawValue,
            "startDate": "2026-01-01T00:00:00.000", "endDate": "2030-12-31T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now,
            "version": 1, "isDeleted": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - Board Edit consolidation — CLOSED (sealed) board fixture

    /// Launch argument that seeds a CLOSED (sealed) board instead of the
    /// active one above — used by `BoardEditOptionsUITests` to exercise the
    /// squares-hidden variant + the BOARD section's Reopen row.
    static let seedClosedBoardArgument = "-uiTestSeedEditBoardClosed"

    /// Id of the seeded closed board.
    static let closedBoardId = "uitest-edit-board-closed"

    /// Seeds the closed-board fixture when its launch argument is present.
    /// Mirrors `seedIfRequested` (same 3×3 task layout, no lock needed since
    /// this fixture never opens the squares grid) but the board is sealed
    /// and its window has ended.
    ///
    /// - Parameter userId: The bypass user's id (owner of every seeded row).
    /// - Throws: Any GRDB write error.
    @MainActor
    static func seedClosedIfRequested(userId: String) throws {
        guard ProcessInfo.processInfo.arguments.contains(seedClosedBoardArgument) else { return }
        let db = AppDatabase.shared
        let now = AppDatabase.currentTimestamp()

        try db.saveBoard(makeClosedBoard(userId: userId, now: now))

        try seedTasks(boardId: closedBoardId, taskIdPrefix: "uitest-closed-task-",
                      boardTaskIdPrefix: "uitest-closed-bt-", lockedTitle: nil,
                      userId: userId, now: now)

        NotificationDelegate.shared.pendingDeepLink = NotificationDeepLink(boardId: closedBoardId)
    }

    /// A CLOSED (sealed), ended, ad-hoc custom 3×3 board with a FREE center —
    /// `BoardMenuItems.canEditSquares` reads false, and the BOARD section
    /// offers Reopen (in place of Close).
    private static func makeClosedBoard(userId: String, now: String) throws -> Board {
        let dict: [String: Any] = [
            "id": closedBoardId, "userId": userId, "name": "UI Test Closed Board",
            "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": Timeframe.custom.rawValue,
            "startDate": "2020-01-01T00:00:00.000", "endDate": "2020-01-31T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now,
            "version": 1, "isDeleted": false,
            "sealedAt": "2020-02-01T00:00:00.000",
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - Wizard Preview → Rearrange fixture

    /// Launch argument that seeds a one-off DRAFT board with all eight tasks
    /// placed — used by `WizardRearrangeUITests`. The draft deep-links like
    /// the fixtures above; its play screen is the draft guard, whose
    /// "Resume draft" button opens the wizard, and a fully-placed draft
    /// resumes straight onto Step 3 (Preview) —
    /// `BoardWizardViewModel.resolveDraftInitialStep`.
    static let seedWizardPreviewArgument = "-uiTestSeedWizardPreview"

    /// Id of the seeded draft board.
    static let wizardDraftBoardId = "uitest-wizard-draft"

    /// Seeds the wizard-preview draft fixture when its launch argument is
    /// present. Same eight titles around a FREE center, none locked,
    /// `isRandomized` false so the Preview grid is the stored placement.
    ///
    /// - Parameter userId: The bypass user's id (owner of every seeded row).
    /// - Throws: Any GRDB write error.
    @MainActor
    static func seedWizardPreviewIfRequested(userId: String) throws {
        guard ProcessInfo.processInfo.arguments.contains(seedWizardPreviewArgument) else { return }
        let db = AppDatabase.shared
        let now = AppDatabase.currentTimestamp()

        try db.saveBoard(makeDraftBoard(userId: userId, now: now))
        try seedTasks(boardId: wizardDraftBoardId, taskIdPrefix: "uitest-draft-task-",
                      boardTaskIdPrefix: "uitest-draft-bt-", lockedTitle: nil,
                      userId: userId, now: now)

        NotificationDelegate.shared.pendingDeepLink = NotificationDeepLink(boardId: wizardDraftBoardId)
    }

    /// A one-off DRAFT custom 3×3 board with a FREE center, not randomized.
    private static func makeDraftBoard(userId: String, now: String) throws -> Board {
        let dict: [String: Any] = [
            "id": wizardDraftBoardId, "userId": userId, "name": "UI Test Draft",
            "status": BoardStatus.draft.rawValue,
            "boardSize": 3, "timeframe": Timeframe.custom.rawValue,
            "startDate": "2026-01-01T00:00:00.000", "endDate": "2030-12-31T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now,
            "version": 1, "isDeleted": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - Shared builders

    /// Upserts the eight fixture tasks "Alpha"…"Theta" and places them in
    /// reading order around the FREE center (1,1) of a 3×3 board.
    ///
    /// - Parameters:
    ///   - boardId: Board the placements belong to.
    ///   - taskIdPrefix: Prefix for the deterministic task ids (suffix = index).
    ///   - boardTaskIdPrefix: Prefix for the deterministic placement ids.
    ///   - lockedTitle: Title of the one square placed LOCKED, or nil for none.
    ///   - userId: Owner of every row.
    ///   - now: Timestamp for created/updated fields.
    /// - Throws: Any GRDB write error.
    private static func seedTasks(
        boardId: String, taskIdPrefix: String, boardTaskIdPrefix: String,
        lockedTitle: String?, userId: String, now: String
    ) throws {
        let db = AppDatabase.shared
        let titles = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta"]
        // Reading-order slots, skipping the FREE center (1,1).
        let slots = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 2), (2, 0), (2, 1), (2, 2)]
        for (i, title) in titles.enumerated() {
            let taskId = "\(taskIdPrefix)\(i)"
            try db.saveTask(Task(
                id: taskId, userId: userId, title: title, description: nil, type: .normal,
                action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
                referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil,
                requiredCount: nil, totalCompletions: 0, totalInstances: 1,
                isCompleted: false, completedAt: nil, currentCount: nil,
                createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
                isDeleted: false, deletedAt: nil
            ))
            let (row, col) = slots[i]
            try db.saveBoardTask(BoardTask(
                id: "\(boardTaskIdPrefix)\(i)", boardId: boardId, taskId: taskId,
                row: row, col: col, isCenter: false,
                isLocked: title == lockedTitle,
                createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
            ))
        }
    }
}
#endif
