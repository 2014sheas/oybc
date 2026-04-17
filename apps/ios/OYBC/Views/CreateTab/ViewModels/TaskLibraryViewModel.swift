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
    /// the authenticated user. Used by `BoardCreatorPanelView` for
    /// step-aware board layouts.
    var allLibraryTaskSteps: [TaskStep] = []

    /// Most recent load error, surfaced to the user as a caption.
    /// Cleared on successful reload.
    var loadError: String?

    // MARK: - Derive panel working state

    /// Steps for the currently-expanded progress task's derive panel.
    var deriveTaskSteps: [TaskStep] = []

    /// Nodes for the currently-expanded composite's derive panel.
    var deriveCompositeNodes: [CompositeNode] = []

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
                DispatchQueue.main.async {
                    self.libraryTasks = fetched
                    self.libraryCompositeTasks = composites
                    self.allLibraryTaskSteps = fetchedSteps
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
    func loadDeriveSteps(for taskId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let steps = try AppDatabase.shared.fetchTaskSteps(taskId: taskId)
                DispatchQueue.main.async {
                    self.deriveTaskSteps = steps
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load steps: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads composite nodes for a single composite into
    /// `deriveCompositeNodes`. Called when the user expands a
    /// composite's derive panel.
    func loadDeriveNodes(for compositeTaskId: String) {
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
                    self.deriveCompositeNodes = nodes
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load composite nodes: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Clears the derive-panel working state. Called on filter change
    /// or when collapsing all rows.
    func clearDeriveState() {
        deriveTaskSteps = []
        deriveCompositeNodes = []
    }
}
