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
        case .compoundNeedsChild: return "A compound task needs a sub-task."
        }
    }
}


/// The unit-task strings the Counter Detail section, its remove confirm and
/// the counter-delete confirm share (docs/SHARED_COUNTER_SETTINGS.md §3d).
/// Web twin: `components/counters/countsTowardLabels.ts` — the strings are
/// pinned identical (except the compound tally, "{done} of {total}" here and
/// "{done} of {total} subtasks" on web).
enum CountsTowardLabels {

    /// "Unit tasks · N"; bare "Unit tasks" when empty.
    static func heading(count: Int) -> String {
        count > 0 ? "Unit tasks \u{00B7} \(count)" : "Unit tasks"
    }

    /// The empty one-liner.
    static let empty = "No unit tasks yet."

    /// "{current} / {goal} {unit}" — `formatCount` by the task's real kind.
    static func progress(_ p: CountsToward.Progress, unit: String?) -> String {
        "\(formatCount(p.current, kind: p.kind)) / \(formatCount(p.goal, kind: p.kind))\(countUnitSuffix(p.kind, unit: unit))"
    }

    /// The compound subtitle: "No subtasks yet" (no children), else "{done} of {total}".
    static func childProgress(_ p: CountsToward.ChildProgress) -> String {
        p.total == 0 ? "No subtasks yet" : "\(p.done) of \(p.total)"
    }

    /// "Remove from {counter}?"
    static func removeTitle(counter: String) -> String { "Remove from \(counter)?" }

    /// "'{title}' stays in your library. Its {N} credits on {counter} are withdrawn."
    static func removeBody(title: String, credits: Int, counter: String) -> String {
        let noun = credits == 1 ? "Its 1 credit" : "Its \(credits) credits"
        let verb = credits == 1 ? "is" : "are"
        return "'\(title)' stays in your library. \(noun) on \(counter) \(verb) withdrawn."
    }

    /// "Its {N} unit tasks are kept as ordinary tasks."; nil at 0.
    static func deleteNote(unitTaskCount: Int) -> String? {
        switch unitTaskCount {
        case ..<1: return nil
        case 1: return "Its 1 unit task is kept as an ordinary task."
        default: return "Its \(unitTaskCount) unit tasks are kept as ordinary tasks."
        }
    }

    /// A failed Remove (web `COUNTER_NOT_UPDATED_MESSAGE`).
    static let counterNotUpdated = "Counter not updated. Try again."

    /// The tag's accessibility label.
    static func tagAccessibility(counter: String) -> String { "Unit task of \(counter)" }

    /// The "+ New" sheet's submit label (every host of that sheet).
    static let submitLabel = "Add to library"

    /// Whether removing a unit task needs the confirm (credits >= 1).
    static func removeNeedsConfirm(creditCount: Int) -> Bool { creditCount >= 1 }
}
