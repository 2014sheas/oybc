import Foundation

// MARK: - SquarePickerCandidates

/// Pure candidate filter for the Board Edit redesign slice 3 Square picker
/// sheet (D13) — lifted out of the retired `CellSwapSheet.swift` so it's
/// unit-testable without SwiftUI. Candidates exclude deleted tasks, tasks
/// already in the DRAFT (not the live board — a staged add/replace this
/// session already occupies a "slot" for counter-family purposes), and
/// shared-counter family-mates of one, plus non-square-eligible types.
enum SquarePickerCandidates {

    /// Task types eligible for a non-center square placement.
    static let eligibleTypes: Set<TaskType> = [.normal, .counting, .compound, .achievement]

    struct Input {
        /// The user's full task library (pending/staged tasks are not
        /// members of this list — they don't exist as `Task` rows yet).
        let candidateTasks: [Task]
        /// The task currently occupying the square being replaced. `nil`
        /// for an Add (empty square) — nothing is excluded on that basis.
        let currentTaskId: String?
        /// Task ids occupying a square in the CURRENT DRAFT (D13) —
        /// including any staged replacement/add, not the live `boardTasks`.
        let placedTaskIds: Set<String>
        /// Task id → shared-counter family key (`BoardSources.buildCounterFamilyMap`).
        let counterFamilyByTaskId: [String: String]
        var query: String = ""
    }

    /// Filters + sorts `input.candidateTasks` down to what the picker shows.
    static func filter(_ input: Input) -> [Task] {
        var placedFamilies = Set<String>()
        for placedId in input.placedTaskIds where placedId != input.currentTaskId {
            if let fam = input.counterFamilyByTaskId[placedId] { placedFamilies.insert(fam) }
        }
        let q = input.query.trimmingCharacters(in: .whitespaces)
        return input.candidateTasks.filter { task in
            guard !task.isDeleted else { return false }
            if task.id == input.currentTaskId { return false }
            if input.placedTaskIds.contains(task.id), task.id != input.currentTaskId { return false }
            if let fam = input.counterFamilyByTaskId[task.id], placedFamilies.contains(fam) {
                return false
            }
            guard eligibleTypes.contains(task.type) else { return false }
            if q.isEmpty { return true }
            return CounterPlacement.taskSearchMatches(q, task: task)
        }
        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }
}
