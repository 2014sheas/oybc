import Foundation
import GRDB

/// Owns the data-loading layer for `BoardPlayView`.
///
/// Moved out of the view in the B2-I1 slice: the seven pieces of state the
/// play surface reads from the local GRDB database (the board record, its
/// placements, and the workspace-wide task/compound/board/template context
/// used by the achievement-config sheet + per-cell badge computation) now
/// live here as `@Published private(set)` state, refreshed by `reload()`.
///
/// House style mirrors `CoreBoardWindowViewModel` in this directory:
/// `@MainActor final class … : ObservableObject`, background dispatch +
/// main-queue apply, and a monotonic `reloadToken` stale-result guard.
///
/// ### Stale-result guard (the one deliberate improvement in this slice)
/// The pre-refactor view fired three independent detached tasks
/// (`loadBoard` / `loadBoardTasks` / `loadTaskData`) that could interleave
/// — a slow earlier read could clobber a newer one's result. `reload()`
/// folds all fetches into ONE background hop and captures a monotonic
/// token; the main-queue apply is dropped if a newer reload has since been
/// requested. So the newest reload always wins.
///
/// ### DB injection
/// `init` takes an `AppDatabase` with a `.shared` default so the view keeps
/// using the production singleton while unit tests can inject a
/// `makeTestInstance()`.
@MainActor
final class BoardPlayViewModel: ObservableObject {

    // MARK: - Published state

    /// The board record for `boardId`, or nil if not (yet) loaded / missing.
    @Published private(set) var board: Board?
    /// Placements for the current board.
    @Published private(set) var boardTasks: [BoardTask] = []
    /// All of the user's tasks (feeds `taskMap`, compound detail sheets,
    /// candidate pickers).
    @Published private(set) var allTasks: [Task] = []
    /// All compound-child links (global, not user-scoped — the DB helper
    /// doesn't filter by userId for that table).
    @Published private(set) var allCompoundChildren: [CompoundChild] = []
    // Phase 6.3 — workspace-wide boards + templates + placements feed both
    // the achievement-square config sheet (pickers) and the per-cell badge
    // data computation. Refreshed alongside the task data so the sheet
    // always sees up-to-date data when opened.
    @Published private(set) var allBoardsInWorkspace: [Board] = []
    @Published private(set) var allTemplatesInWorkspace: [RecurringBoardTemplate] = []
    @Published private(set) var allBoardTasksInWorkspace: [BoardTask] = []

    // MARK: - Config

    /// The board this view model loads. Mutable so the embedded core-board
    /// pager can point the same (reused) view model at a new board via
    /// `boardChanged(to:)` without recreating it.
    private(set) var boardId: String
    /// The authenticated user's id. Set at init for tests; the view supplies
    /// it in `.onAppear` via `setUserId` because its `@EnvironmentObject`
    /// `AuthService` isn't available in a SwiftUI `init`.
    private var userId: String?
    private let database: AppDatabase

    // MARK: - Stale-result guard

    /// Monotonically-increasing token incremented on every reload call. Each
    /// in-flight background fetch captures the token at dispatch and only
    /// applies its result if `reloadToken` still matches when it completes on
    /// the main queue — so a slower earlier fetch can't overwrite a newer
    /// reload's result. Mirrors the identical pattern in
    /// `CoreBoardWindowViewModel` / `CoreBoardBrowserViewModel`.
    private var reloadToken: Int = 0

    // MARK: - Init

    /// - Parameters:
    ///   - boardId: The board to load.
    ///   - userId: The authenticated user's id (nilable: the view constructs
    ///     the view model in its `init`, where the `@EnvironmentObject`
    ///     `AuthService` is not yet available, so it passes nil here and
    ///     supplies the real id in `.onAppear` via `setUserId`). Tests pass a
    ///     real id at init. When nil, the user-scoped fetches (tasks /
    ///     workspace boards / templates) resolve to empty arrays, matching
    ///     the pre-refactor `loadTaskData` behavior.
    ///   - database: Injected for tests; defaults to the production singleton.
    init(boardId: String, userId: String?, database: AppDatabase = .shared) {
        self.boardId = boardId
        self.userId = userId
        self.database = database
    }

    /// Supply the authenticated user's id. Called by the view in `.onAppear`
    /// (where its `@EnvironmentObject` is available). Does not trigger a
    /// reload — the caller reloads immediately after.
    func setUserId(_ userId: String?) {
        self.userId = userId
    }

    // MARK: - Actions

    /// Full reload: the board record, its placements, and the workspace-wide
    /// task/compound/board/template context — all in one background hop,
    /// applied atomically on the main queue under the stale-result guard.
    ///
    /// Replaces the pre-refactor `loadBoard()` + `loadBoardTasks()` +
    /// `loadTaskData()` trio. Every site that called all three now calls
    /// this; the two dismiss handlers that called only the latter two use
    /// `reloadBoardTasksAndTaskData()` instead to preserve their scope.
    func reload() {
        reloadToken += 1
        let token = reloadToken
        let boardId = self.boardId
        let userId = self.userId
        let database = self.database

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let board = try? database.fetchBoard(id: boardId)
            let payload = Self.fetchTaskData(boardId: boardId, userId: userId, database: database)
            DispatchQueue.main.async {
                guard token == self.reloadToken else { return }
                self.board = board
                self.apply(payload)
            }
        }
    }

    /// Partial reload used by sheet-dismiss handlers that did NOT change the
    /// board record itself (the M3 swap sheet + the M4 add-to-cell cancel
    /// path): refreshes placements + task/compound + workspace data, but not
    /// `board`. Preserves the pre-refactor sites that called
    /// `loadBoardTasks()` + `loadTaskData()` without `loadBoard()`.
    func reloadBoardTasksAndTaskData() {
        reloadToken += 1
        let token = reloadToken
        let boardId = self.boardId
        let userId = self.userId
        let database = self.database

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let payload = Self.fetchTaskData(boardId: boardId, userId: userId, database: database)
            DispatchQueue.main.async {
                guard token == self.reloadToken else { return }
                self.apply(payload)
            }
        }
    }

    /// Point the view model at a new board and reload. Used by the view's
    /// `.onChange(of: boardId)` so the embedded core-board pager — which
    /// swaps the board id on the SAME (reused) `BoardPlayView` instance,
    /// without a `.id()` modifier to force a fresh view identity — refreshes
    /// correctly. In the standalone route the `.id(boardId)` on the
    /// navigation destination recreates the view (and this view model) per
    /// board, so this path is the defensive one for the reuse case.
    func boardChanged(to newBoardId: String) {
        boardId = newBoardId
        reload()
    }

    // MARK: - Private

    /// The workspace-wide fetch bundle shared by `reload()` and
    /// `reloadBoardTasksAndTaskData()`. Pure + `nonisolated` so it runs on the
    /// background queue. Mirrors the pre-refactor `loadTaskData` fetch set
    /// (plus the board's own placements) exactly.
    private nonisolated static func fetchTaskData(
        boardId: String,
        userId: String?,
        database: AppDatabase
    ) -> TaskDataPayload {
        let boardTasks = (try? database.fetchBoardTasks(boardId: boardId)) ?? []
        let tasks = userId.flatMap { id in try? database.fetchTasks(userId: id) } ?? []
        let children = (try? database.fetchAllCompoundChildren()) ?? []
        let workspaceBoards = userId.flatMap { id in try? database.fetchBoards(userId: id) } ?? []
        let workspaceTemplates = userId.flatMap { id in
            try? database.fetchRecurringBoardTemplates(userId: id)
        } ?? []
        let workspaceBoardTasks = (try? database.fetchAllBoardTasks()) ?? []
        return TaskDataPayload(
            boardTasks: boardTasks,
            allTasks: tasks,
            allCompoundChildren: children,
            allBoardsInWorkspace: workspaceBoards,
            allTemplatesInWorkspace: workspaceTemplates,
            allBoardTasksInWorkspace: workspaceBoardTasks
        )
    }

    private func apply(_ payload: TaskDataPayload) {
        boardTasks = payload.boardTasks
        allTasks = payload.allTasks
        allCompoundChildren = payload.allCompoundChildren
        allBoardsInWorkspace = payload.allBoardsInWorkspace
        allTemplatesInWorkspace = payload.allTemplatesInWorkspace
        allBoardTasksInWorkspace = payload.allBoardTasksInWorkspace
    }

    /// Snapshot of the task-data fetch bundle, passed from the background
    /// queue to the main-queue apply.
    private struct TaskDataPayload {
        let boardTasks: [BoardTask]
        let allTasks: [Task]
        let allCompoundChildren: [CompoundChild]
        let allBoardsInWorkspace: [Board]
        let allTemplatesInWorkspace: [RecurringBoardTemplate]
        let allBoardTasksInWorkspace: [BoardTask]
    }
}
