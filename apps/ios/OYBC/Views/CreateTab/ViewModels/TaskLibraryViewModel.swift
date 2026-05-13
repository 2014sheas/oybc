import Foundation
import GRDB
import Observation

/// Filter options for the Existing Tasks tab. Five user-facing tabs map
/// onto two underlying classifications (mirrors web's ExistingFilter):
///   - .all       → every task
///   - .normal    → type=.normal
///   - .counting  → type=.counting
///   - .progress  → type=.compound && isOrdered=true
///   - .composite → type=.compound && isOrdered!=true
enum LibraryFilter: String, CaseIterable {
    case all = "All"
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    case composite = "Composite"
    /// Phase 6.1: tasks placed on currently-active longer-window parent
    /// boards. Only surfaced in the board wizard's tasks step (and only
    /// when the wizard's timeframe has parents — daily/weekly/monthly).
    /// `filteredTasks` returns [] for this case because the source isn't
    /// the user's library — it's a separate `ParentBoardTasksViewModel`
    /// query, special-cased in BoardWizardTasksStepView.
    case fromParents = "From parent boards"
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
    var libraryTasks: [Task] = []

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

    /// Most recent load error, surfaced to the user as a caption.
    /// Cleared on successful reload.
    var loadError: String?

    // MARK: - Filtered queries (computed)

    /// Filtered task list for the active library tab.
    func filteredTasks(_ filter: LibraryFilter) -> [Task] {
        switch filter {
        case .all:
            return libraryTasks
        case .normal:
            return libraryTasks.filter { $0.type == .normal }
        case .counting:
            return libraryTasks.filter { $0.type == .counting }
        case .progress:
            return libraryTasks.filter { $0.type == .compound && $0.isOrdered == true }
        case .composite:
            return libraryTasks.filter { $0.type == .compound && $0.isOrdered != true }
        case .fromParents:
            // Source is a separate ParentBoardTasksViewModel — see
            // BoardWizardTasksStepView. Returning [] here is correct;
            // generic library consumers shouldn't see anything for this filter.
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
            await MainActor.run {
                self.libraryTasks = tasks
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
}
