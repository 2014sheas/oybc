import Foundation
import GRDB
import Observation

/// Filter options for the Existing Tasks tab. Four user-facing tabs map
/// onto the unified TaskType values (mirrors web's ExistingFilter):
///   - .all      → every task
///   - .normal   → type=.normal
///   - .counting → type=.counting
///   - .compound → type=.compound (both ordered and unordered)
/// The former .progress / .composite split is retired — both authored via
/// the compound wizard with the Ordered steps toggle.
enum LibraryFilter: String, CaseIterable {
    case all = "All"
    case normal = "Normal"
    case counting = "Counting"
    case compound = "Compound"
    /// Phase 6.1: tasks placed on currently-active longer-window parent
    /// boards. Only surfaced in the board wizard's tasks step (and only
    /// when the wizard's timeframe has parents — daily/weekly/monthly).
    /// `filteredTasks` returns [] for this case because the source isn't
    /// the user's library — it's a separate `ParentBoardTasksViewModel`
    /// query, special-cased in BoardWizardTasksStepView.
    case fromParents = "From parent boards"
    /// Wizard "From a board" picker — swaps the list region for a
    /// source-board picker (and then for that board's grid). Always
    /// available in the wizard regardless of timeframe; never surfaces
    /// in the standalone Tasks tab. Special-cased in
    /// BoardWizardTasksStepView's list switch.
    case fromBoard = "From a board…"
}

/// Owns the user's task library + derive-panel working set under the
/// unified compound model. iOS twin of web's useTaskLibrary hook
/// (Phase 4.1).
///
/// All compounds live in `libraryTasks` with type=.compound. The
/// legacy composite_tasks / composite_nodes / task_steps tables are
/// no longer used by this view-model; it only touches `tasks` and
/// `compound_children`. (The legacy tables are not actually dropped
/// by GRDB v7 — MigrationV7Helpers only DELETEs their rows so the
/// sync queue can drain corresponding Firestore tombstones; a future
/// cleanup migration can drop them once the sync queue is verified
/// empty across devices.)
///
/// Uses @Observable so SwiftUI observes field-level reads.
@Observable
final class TaskLibraryViewModel {

    // MARK: - Library data

    /// All non-deleted tasks for the authenticated user, ordered by title.
    /// Includes every TaskType (.normal / .counting / .compound / .progress
    /// alias for legacy rows).
    ///
    /// This is the FULL set, used for id-resolution everywhere (placement
    /// lookup, the resumed-draft grid/pool, task-by-id). Browse surfaces
    /// must use `browsableTasks` instead — see below.
    var libraryTasks: [Task] = []

    /// `libraryTasks` minus wizard-born tasks that aren't yet on a live board.
    /// This is the set the LIBRARY-BROWSE surfaces show — the Tasks tab and the
    /// wizard's "add from library" picker — so a task created inside the board
    /// wizard stays hidden until its board goes active. Visibility rule (see
    /// `computeBrowsableTasks`): hide iff `createdInWizard` AND no effective
    /// (own ∪ parent-compound) placement on a non-draft board — i.e. draft-only
    /// OR orphaned (removed from the pool / board deleted). Only standalone
    /// tasks are unconditionally visible. Keep `libraryTasks` for resolution;
    /// never browse it.
    var browsableTasks: [Task] = []

    /// All non-deleted compound_children rows in the workspace.
    /// Small-N (one row per parent-child link, typically under a few hundred
    /// per user). Used by the wizard / board grid / detail sheet to resolve
    /// compound children without re-fetching per-render.
    var allCompoundChildren: [CompoundChild] = []

    /// Pre-grouped + sorted-by-childIndex map keyed by parent compoundTaskId.
    /// Computed from allCompoundChildren on every reload — saves consumers
    /// from re-grouping in their own renders.
    var compoundChildrenByCompound: [String: [CompoundChild]] = [:]

    /// All BoardTasks across every board (any user). Used by
    /// `BoardWizardTasksStepView` to compute the "N boards" usage hint per
    /// task — parity with the composite wizard's library rows. BoardTask
    /// has no `userId` or `isDeleted` columns under the unified model;
    /// fetching the full table and tallying in-memory is fine at small N.
    var allLibraryBoardTasks: [BoardTask] = []

    /// Every task id that appears as a child of at least one compound.
    /// Recomputed on each reload alongside compoundChildrenByCompound.
    /// iOS twin of web's `TaskLibrary.childTaskIds`. (#73)
    var childTaskIds: Set<String> = []

    /// Reverse map: child task id → array of parent compound task ids.
    /// A child may belong to multiple parents.
    /// iOS twin of web's `TaskLibrary.childToParents`. (#73)
    var childToParents: [String: [String]] = [:]

    /// Most recent load error, surfaced to the user as a caption.
    /// Cleared on successful reload.
    var loadError: String?

    // MARK: - Filtered queries (computed)

    /// Filtered task list for the active library tab. Browses
    /// `browsableTasks` (the draft-filtered set) — this is a browse helper,
    /// never a resolution path, so it must hide draft-only wizard tasks like
    /// every other browse surface. (Currently has no live caller; the Tasks
    /// tab uses `TasksTabViewModel.filteredTasks(library:)`. Kept consistent
    /// so wiring it up later can't reintroduce the leak.)
    func filteredTasks(_ filter: LibraryFilter) -> [Task] {
        switch filter {
        case .all:
            return browsableTasks
        case .normal:
            return browsableTasks.filter { $0.type == .normal }
        case .counting:
            return browsableTasks.filter { $0.type == .counting }
        case .compound:
            return browsableTasks.filter { $0.type == .compound }
        case .fromParents:
            // Source is a separate ParentBoardTasksViewModel — see
            // BoardWizardTasksStepView. Returning [] here is correct;
            // generic library consumers shouldn't see anything for this filter.
            return []
        case .fromBoard:
            // Source is a separate SourceBoardsViewModel — see
            // BoardWizardTasksStepView. Returning [] mirrors .fromParents
            // for generic library consumers.
            return []
        }
    }

    /// Look up a Task by id. O(N) since libraryTasks is small; if N grows,
    /// switch to a maintained dictionary.
    func task(byId id: String) -> Task? {
        libraryTasks.first { $0.id == id }
    }

    // MARK: - Lifecycle

    /// Reloads libraryTasks + allCompoundChildren + allLibraryBoardTasks
    /// from the local database. Called on .onAppear of the consuming views
    /// and after each task creation/edit so the library stays consistent.
    func reload(userId: String) async {
        do {
            let tasks = try await Self.loadTasks(userId: userId)
            let children = try await Self.loadCompoundChildren()
            let boardTasks = try await Self.loadAllBoardTasks()
            let boardStatusById = try await Self.loadBoardStatuses(userId: userId)
            // #73 — child-id set + reverse (child → parents) map, derived up
            // front because the browsable filter needs it (compound children
            // inherit their parent compound's placements).
            var childIds = Set<String>()
            var reverseMap: [String: [String]] = [:]
            for c in children {
                childIds.insert(c.childTaskId)
                reverseMap[c.childTaskId, default: []].append(c.compoundTaskId)
            }
            let browsable = Self.computeBrowsableTasks(
                tasks: tasks,
                boardTasks: boardTasks,
                boardStatusById: boardStatusById,
                childToParents: reverseMap
            )
            await MainActor.run {
                self.libraryTasks = tasks
                self.browsableTasks = browsable
                self.allCompoundChildren = children
                self.allLibraryBoardTasks = boardTasks
                var grouped: [String: [CompoundChild]] = [:]
                for c in children {
                    grouped[c.compoundTaskId, default: []].append(c)
                }
                for id in grouped.keys {
                    grouped[id]?.sort { $0.childIndex < $1.childIndex }
                }
                self.compoundChildrenByCompound = grouped
                self.childTaskIds = childIds
                self.childToParents = reverseMap
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                self.loadError = "Failed to load library: \(error.localizedDescription)"
            }
        }
    }

    /// Sync shim for view-side fire-and-forget callers (the board-wizard +
    /// playgrounds use this from `.onAppear` and refresh callbacks where an
    /// async context isn't readily available). Wraps `reload(userId:)` in a
    /// detached `_Concurrency.Task`.
    func loadLibrary(userId: String) {
        _Concurrency.Task { await reload(userId: userId) }
    }

    private static func loadTasks(userId: String) async throws -> [Task] {
        try await AppDatabase.shared.read { db in
            try Task
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    private static func loadCompoundChildren() async throws -> [CompoundChild] {
        try await AppDatabase.shared.read { db in
            try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    private static func loadAllBoardTasks() async throws -> [BoardTask] {
        try await AppDatabase.shared.read { db in
            try BoardTask.fetchAll(db)
        }
    }

    /// Map of non-deleted boardId → status for the user. Drives the
    /// draft-only-visibility filter (a placement on a deleted board is
    /// absent from this map and therefore ignored).
    private static func loadBoardStatuses(userId: String) async throws -> [String: BoardStatus] {
        try await AppDatabase.shared.read { db in
            let boards = try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
            return Dictionary(boards.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Pure visibility filter for library-browse surfaces (Tasks tab + wizard
    /// "add from library"). Hides a wizard-born task (`createdInWizard`) that
    /// has NO placement on a live non-draft board — i.e. it lives only on
    /// drafts, or has no live placement at all (an orphan: removed from the
    /// pool, so its Task row lingers after persist drops the board_task; or its
    /// board was deleted). Standalone/copied tasks (`createdInWizard == false`)
    /// are always visible.
    ///
    /// Compound children inherit their parent compound's placements — a
    /// wizard-born inline subtask is never *directly* placed (it lives under
    /// its parent), so without inheritance it would look like a placement-less
    /// orphan and hide forever. With inheritance it's visible exactly when its
    /// parent compound is (keeping wizard-created subtasks pool-addable).
    ///
    /// Visible iff: `!createdInWizard` OR ≥1 effective (own ∪ inherited)
    /// non-draft placement.
    ///
    /// - Parameters:
    ///   - tasks: The full library task set.
    ///   - boardTasks: Every BoardTask row (any board).
    ///   - boardStatusById: Non-deleted boardId → status (placements on
    ///     missing/deleted boards are ignored).
    ///   - childToParents: child taskId → parent compound taskId(s); a child's
    ///     effective placements are its own ∪ its parents'.
    static func computeBrowsableTasks(
        tasks: [Task],
        boardTasks: [BoardTask],
        boardStatusById: [String: BoardStatus],
        childToParents: [String: [String]] = [:]
    ) -> [Task] {
        // taskId → set of non-deleted board ids it's placed on.
        var placementsByTask: [String: Set<String>] = [:]
        for bt in boardTasks {
            guard boardStatusById[bt.boardId] != nil else { continue }
            placementsByTask[bt.taskId, default: []].insert(bt.boardId)
        }
        return tasks.filter { task in
            guard task.createdInWizard else { return true }
            // Effective placements: own + inherited from parent compound(s).
            var boardIds = placementsByTask[task.id] ?? []
            for parentId in childToParents[task.id] ?? [] {
                boardIds.formUnion(placementsByTask[parentId] ?? [])
            }
            // No live placement (direct or inherited) → orphan → hidden.
            // (Was `return true`, which leaked deleted-in-wizard tasks into the
            // library; hiding an orphan is safe — it reappears if it later
            // lands on a live board.)
            if boardIds.isEmpty { return false }
            return boardIds.contains { boardStatusById[$0] != .draft }
        }
    }
}
