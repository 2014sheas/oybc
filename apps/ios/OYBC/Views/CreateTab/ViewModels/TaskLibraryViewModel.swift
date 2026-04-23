import Foundation
import GRDB
import Observation

/// Filter options for the Existing Tasks tab. Mirrors the web
/// `LibraryFilter` type.
enum LibraryFilter: String, CaseIterable {
    case all = "All"
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    case composite = "Composite"
}

/// Owns the user's task/composite library + derive-panel working sets
/// for the Create tab. Mirrors web's `useTaskLibrary` hook (which
/// wraps `useLiveQuery` observations) with GRDB async reads kicked
/// off from view lifecycle methods.
///
/// The `deriveTaskSteps` / `deriveCompositeNodes` fields are scoped
/// state for the currently-expanded derivation panel — loaded on
/// expand, cleared on collapse.
///
/// Uses `@Observable` so SwiftUI observes field-level reads.
@Observable
final class TaskLibraryViewModel {

    // MARK: - Library data

    /// All non-deleted tasks for the authenticated user, ordered by title.
    var libraryTasks: [Task] = []

    /// All non-deleted composite tasks for the authenticated user, ordered by title.
    var libraryCompositeTasks: [CompositeTask] = []

    /// All non-deleted task steps belonging to progress tasks owned by
    /// the authenticated user. Consumed by preview components that
    /// need per-step progress fractions.
    var allLibraryTaskSteps: [TaskStep] = []

    /// All non-deleted BoardTasks across every board (any user). Used
    /// by `BoardWizardTasksStepView` to compute the "N boards" usage
    /// hint per task — parity with the composite wizard's library rows.
    var allLibraryBoardTasks: [BoardTask] = []

    /// All non-deleted CompositeNodes for the authenticated user's
    /// composites. Used to resolve leaf previews + leaf task lists
    /// inline on the board-wizard Tasks step, replacing the heavier
    /// per-composite `deriveCompositeNodes` load that only covered
    /// the currently-expanded row.
    var allLibraryCompositeNodes: [CompositeNode] = []

    /// Most recent load error, surfaced to the user as a caption.
    /// Cleared on successful reload.
    var loadError: String?

    // MARK: - Derive panel working state

    /// Steps for the currently-expanded progress task's derive panel.
    var deriveTaskSteps: [TaskStep] = []

    /// Nodes for the currently-expanded composite's derive panel.
    var deriveCompositeNodes: [CompositeNode] = []

    /// Most-recent `taskId` requested via `loadDeriveSteps`. Guards
    /// against a slower earlier fetch landing after a faster later
    /// one and overwriting state for the currently-expanded row —
    /// easy to hit by rapidly tapping between two progress tasks.
    private var activeDeriveStepsTaskId: String?

    /// Most-recent `compositeTaskId` requested via
    /// `loadDeriveNodes`. Same race guard as above for composites.
    private var activeDeriveNodesCompositeTaskId: String?

    // MARK: - Filters

    /// Applies the Existing-Tasks filter to `libraryTasks`. Composites
    /// have their own filter path because they live in a separate table.
    func filteredTasks(filter: LibraryFilter) -> [Task] {
        switch filter {
        case .all:       return libraryTasks
        case .normal:    return libraryTasks.filter { $0.type == .normal }
        case .counting:  return libraryTasks.filter { $0.type == .counting }
        case .progress:  return libraryTasks.filter { $0.type == .progress }
        case .composite: return []
        }
    }

    func filteredComposites(filter: LibraryFilter) -> [CompositeTask] {
        switch filter {
        case .all, .composite: return libraryCompositeTasks
        default:               return []
        }
    }

    // MARK: - Data loading

    /// Reloads `libraryTasks`, `libraryCompositeTasks`, and
    /// `allLibraryTaskSteps` off the main queue; commits results on the
    /// main queue so SwiftUI observers see a consistent snapshot.
    func loadLibrary(userId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let fetched = try AppDatabase.shared.fetchTasks(userId: userId)
                let composites = try AppDatabase.shared.read { db in
                    try CompositeTask
                        .filter(Column("userId") == userId && Column("isDeleted") == false)
                        .order(Column("title"))
                        .fetchAll(db)
                }
                let fetchedSteps = try AppDatabase.shared.fetchAllTaskSteps(userId: userId)
                // Scoped fetches for the new usage-hint + leaf-preview
                // work. BoardTasks have no `userId` column, but we only
                // count boardIds per task, so the full table is fine.
                // CompositeNodes filter by the user's composite ids.
                let boardTasks: [BoardTask] = try AppDatabase.shared.read { db in
                    try BoardTask
                        .filter(Column("isDeleted") == false)
                        .fetchAll(db)
                }
                let compositeIds = composites.map { $0.id }
                let compositeNodes: [CompositeNode] = compositeIds.isEmpty
                    ? []
                    : try AppDatabase.shared.read { db in
                        try CompositeNode
                            .filter(compositeIds.contains(Column("compositeTaskId")) && Column("isDeleted") == false)
                            .fetchAll(db)
                    }
                DispatchQueue.main.async {
                    self.libraryTasks = fetched
                    self.libraryCompositeTasks = composites
                    self.allLibraryTaskSteps = fetchedSteps
                    self.allLibraryBoardTasks = boardTasks
                    self.allLibraryCompositeNodes = compositeNodes
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load tasks: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads the step list for a single progress task into
    /// `deriveTaskSteps`. Called when the user expands a progress
    /// task's derive panel.
    ///
    /// Results are only committed if the in-flight request is still
    /// the most recent one — an older fetch landing late (because
    /// the user rapidly switched to a different progress task) is
    /// discarded so it can't overwrite the currently-expanded state.
    func loadDeriveSteps(for taskId: String) {
        activeDeriveStepsTaskId = taskId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let steps = try AppDatabase.shared.fetchTaskSteps(taskId: taskId)
                DispatchQueue.main.async {
                    guard self.activeDeriveStepsTaskId == taskId else { return }
                    self.deriveTaskSteps = steps
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.activeDeriveStepsTaskId == taskId else { return }
                    self.loadError = "Failed to load steps: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads composite nodes for a single composite into
    /// `deriveCompositeNodes`. Called when the user expands a
    /// composite's derive panel.
    ///
    /// Same stale-result guard as `loadDeriveSteps`: rapid expand/
    /// collapse across different composites can cause an earlier
    /// fetch to land after a later one; the guard drops results that
    /// no longer match the currently-expanded id.
    func loadDeriveNodes(for compositeTaskId: String) {
        activeDeriveNodesCompositeTaskId = compositeTaskId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let nodes = try AppDatabase.shared.read { db in
                    try CompositeNode
                        .filter(
                            Column("compositeTaskId") == compositeTaskId
                            && Column("isDeleted") == false
                        )
                        .fetchAll(db)
                }
                DispatchQueue.main.async {
                    guard self.activeDeriveNodesCompositeTaskId == compositeTaskId else { return }
                    self.deriveCompositeNodes = nodes
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.activeDeriveNodesCompositeTaskId == compositeTaskId else { return }
                    self.loadError = "Failed to load composite nodes: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Clears the derive-panel working state. Called on filter change
    /// or when collapsing all rows.
    func clearDeriveState() {
        activeDeriveStepsTaskId = nil
        activeDeriveNodesCompositeTaskId = nil
        deriveTaskSteps = []
        deriveCompositeNodes = []
    }
}
