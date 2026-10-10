import Foundation

// MARK: - "Counts toward" — user-facing refusal labels

extension CountsToward.Problem {
    /// The validation line a task editor / create form shows when the write is
    /// refused (docs/SHARED_COUNTER_SETTINGS.md §3, PR 4). Web twin:
    /// `countsTowardProblemLabel`.
    var label: String {
        switch self {
        case .selfTarget: return "Not itself."
        case .contributorIsCounter: return "A counter can't count toward a counter."
        case .contributorIsLinked: return "A linked counter can't count toward a counter."
        case .contributorIsAchievement: return "An achievement can't count toward a counter."
        case .targetNotCounter: return "Pick a shared counter."
        case .targetNotDiscrete: return "Pick a Discrete counter."
        case .invalidAmount: return "Amount must be a whole number, 1 or more."
        case .cycle: return "That counter already feeds this task."
        }
    }
}

extension AppDatabase.CountsTowardError {
    /// The line an editor shows for a refused counts-toward write; nil for a
    /// missing task (the caller's generic error covers it).
    var label: String? {
        switch self {
        case .taskMissing: return nil
        case .refused(let problem): return problem.label
        }
    }
}
