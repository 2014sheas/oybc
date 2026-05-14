import Foundation
import GRDB
import Observation

/// Type-filter chips on the Tasks tab. Mirrors the wizard's filter set
/// but adds `.achievement` (which the wizard hides because achievements
/// aren't placeable on a board pool).
enum TasksTabTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    case composite = "Composite"
    case achievement = "Achievement"
    var id: String { rawValue }
}

/// Status-filter dropdown values. "Never started" = not completed and
/// no progress signal; "In progress" = some signal but not done.
enum TasksTabStatusFilter: String, CaseIterable, Identifiable {
    case any = "Any status"
    case completed = "Completed"
    case inProgress = "In progress"
    case neverStarted = "Never started"
    var id: String { rawValue }
}

/// Usage-filter dropdown values. Computed from `BoardTask` joined to
/// `Board.status`.
enum TasksTabUsageFilter: String, CaseIterable, Identifiable {
    case any = "Any usage"
    case unused = "Unused"
    case onActiveBoards = "On active boards"
    var id: String { rawValue }
}

/// Sort options for the Tasks list.
enum TasksTabSort: String, CaseIterable, Identifiable {
    case updatedDesc = "Recently updated"
    case createdDesc = "Recently created"
    case completedDesc = "Recently completed"
    case titleAsc = "Title (A→Z)"
    case mostUsedDesc = "Most-used"
    var id: String { rawValue }
}

/// Owns the Tasks-tab filter / sort state plus a board-status lookup
/// for the usage filter ("on active boards"). The library data itself
/// is loaded by a paired `TaskLibraryViewModel` instance on the view;
/// this view-model only adds the bits the Tasks tab needs on top.
///
/// Mirrors the web `useTasksFilters` hook in `apps/web/src/pages/tasks/`.
@Observable
final class TasksTabViewModel {

    // MARK: - Filter / sort state

    var search: String = ""
    var typeFilter: TasksTabTypeFilter = .all
    var statusFilter: TasksTabStatusFilter = .any
    var usageFilter: TasksTabUsageFilter = .any
    var sortBy: TasksTabSort = .updatedDesc

    // MARK: - Joined board-status data

    /// Status map for non-deleted boards. Loaded once per `reload`; the
    /// usage filter and the row's "On N active boards" hint both read it.
    var boardStatusById: [String: BoardStatus] = [:]

    /// Most recent reload error, surfaced to the user as a caption.
    var loadError: String?

    // MARK: - Lifecycle

    func reload() async {
        do {
            let boards = try await Self.loadBoards()
            await MainActor.run {
                var m: [String: BoardStatus] = [:]
                for b in boards {
                    m[b.id] = b.status
                }
                self.boardStatusById = m
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                self.loadError = "Failed to load board statuses: \(error.localizedDescription)"
            }
        }
    }

    func reloadAsync() {
        _Concurrency.Task { await reload() }
    }

    // MARK: - Derived placement counts

    /// `taskId` → count of non-deleted BoardTask placements (any board
    /// status). Used for the "Most-used" sort and "Placed on N boards"
    /// hint when there are no active-board placements.
    func placementCounts(boardTasks: [BoardTask]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for bt in boardTasks {
            counts[bt.taskId, default: 0] += 1
        }
        return counts
    }

    /// `taskId` → count of placements on boards whose `status == .active`.
    /// Drives the usage filter's "On active boards" value plus the row's
    /// primary usage hint.
    func activePlacementCounts(boardTasks: [BoardTask]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for bt in boardTasks where boardStatusById[bt.boardId] == .active {
            counts[bt.taskId, default: 0] += 1
        }
        return counts
    }

    // MARK: - Pipeline

    /// Filter + sort the library against the current state. Pure given
    /// the library snapshot and the count maps.
    func filteredTasks(library: TaskLibraryViewModel) -> [Task] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let placementCounts = placementCounts(boardTasks: library.allLibraryBoardTasks)
        let activeCounts = activePlacementCounts(boardTasks: library.allLibraryBoardTasks)

        let typed = library.libraryTasks
            .filter { Self.matchesType($0, typeFilter) }
            .filter { Self.matchesSearch($0, trimmedLower: trimmed) }
            .filter { Self.matchesStatus($0, library: library, filter: statusFilter) }

        let used = Self.applyUsage(
            typed,
            filter: usageFilter,
            placementCounts: placementCounts,
            activeCounts: activeCounts,
        )

        return used.sorted { Self.compare($0, $1, sort: sortBy, placementCounts: placementCounts) }
    }

    // MARK: - Pure helpers (mirror useTasksFilters.ts)

    static func matchesType(_ task: Task, _ filter: TasksTabTypeFilter) -> Bool {
        switch filter {
        case .all: return true
        case .normal: return task.type == .normal
        case .counting: return task.type == .counting
        case .progress: return task.type == .compound && task.isOrdered == true
        case .composite: return task.type == .compound && task.isOrdered != true
        case .achievement: return task.type == .achievement
        }
    }

    static func matchesSearch(_ task: Task, trimmedLower: String) -> Bool {
        guard !trimmedLower.isEmpty else { return true }
        if task.title.lowercased().contains(trimmedLower) { return true }
        if let desc = task.description, desc.lowercased().contains(trimmedLower) { return true }
        return false
    }

    static func matchesStatus(
        _ task: Task,
        library: TaskLibraryViewModel,
        filter: TasksTabStatusFilter,
    ) -> Bool {
        if filter == .any { return true }
        let inProgress = Self.isInProgress(task, library: library)
        switch filter {
        case .any: return true
        case .completed: return task.isCompleted
        case .inProgress: return !task.isCompleted && inProgress
        case .neverStarted: return !task.isCompleted && !inProgress
        }
    }

    /// "In progress" predicate. Counting tasks: `currentCount > 0` and
    /// not done. Compound tasks: at least one child Task is completed
    /// but the parent isn't (child completion state read out of
    /// `library.libraryTasks` via id match).
    static func isInProgress(_ task: Task, library: TaskLibraryViewModel) -> Bool {
        if task.isCompleted { return false }
        if task.type == .counting {
            return (task.currentCount ?? 0) > 0
        }
        if task.type == .compound {
            let children = library.compoundChildrenByCompound[task.id] ?? []
            for link in children {
                if let child = library.task(byId: link.childTaskId), child.isCompleted {
                    return true
                }
            }
            return false
        }
        return false
    }

    static func applyUsage(
        _ tasks: [Task],
        filter: TasksTabUsageFilter,
        placementCounts: [String: Int],
        activeCounts: [String: Int],
    ) -> [Task] {
        switch filter {
        case .any: return tasks
        case .unused: return tasks.filter { (placementCounts[$0.id] ?? 0) == 0 }
        case .onActiveBoards: return tasks.filter { (activeCounts[$0.id] ?? 0) > 0 }
        }
    }

    static func compare(
        _ a: Task,
        _ b: Task,
        sort: TasksTabSort,
        placementCounts: [String: Int],
    ) -> Bool {
        switch sort {
        case .titleAsc:
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        case .createdDesc:
            return a.createdAt > b.createdAt
        case .updatedDesc:
            return a.updatedAt > b.updatedAt
        case .completedDesc:
            if let ac = a.completedAt, let bc = b.completedAt {
                return ac > bc
            }
            if a.completedAt != nil { return true }
            if b.completedAt != nil { return false }
            return a.updatedAt > b.updatedAt
        case .mostUsedDesc:
            let ca = placementCounts[a.id] ?? 0
            let cb = placementCounts[b.id] ?? 0
            if ca != cb { return ca > cb }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    // MARK: - Data loaders

    private static func loadBoards() async throws -> [Board] {
        try await AppDatabase.shared.read { db in
            try Board
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
        }
    }
}
