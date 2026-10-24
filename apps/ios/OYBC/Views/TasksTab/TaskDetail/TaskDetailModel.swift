import Foundation

// MARK: - TaskDetailModel

/// Everything the Task Detail screen draws, as plain values (docs/TASK_DETAIL_REDESIGN.md
/// §PR 4). `TaskDetailViewModel` builds it from the database and the anchor board's
/// windowed reads; the views render it with no database, so every state is
/// snapshot-testable. Web twin: `pages/tasks/taskDetailModel.ts`.
struct TaskDetailModel: Equatable {

    /// The achievement hero: the watched-board card with its closest line.
    struct AchievementHero: Equatable {
        let card: SquareSheetContent.Achievement
        /// The watched board's best unfinished line (nil when none can be read or all are complete).
        let closestLine: TaskDetailKernel.ClosestLine?
        /// Per-cell completion of that line, in reading order.
        var lineCells: [Bool] = []
    }

    /// The hero's one live control. `.none` = no anchor board: no control, no count.
    enum Hero: Equatable {
        case none
        case counting(SquareSheetContent.ChildCount)
        /// A counting task with no square in play: the all-time count, logging "now".
        case boardlessCounting(SquareSheetContent.ChildCount)
        case normal(isDone: Bool, sealBlocked: Bool)
        case compound(SquareSheetContent.Compound, ruleLabel: String)
        case achievement(AchievementHero)
    }

    /// A counter row (hero + Links): "Shared counter" / "Counts toward".
    struct CounterLink: Equatable {
        let counterId: String
        let label: String
        let name: String
        /// "1,240" — `formatCountTotal` in the root's kind.
        let total: String
        /// Trailing unit, e.g. "pages" (empty for duration).
        let unit: String
    }

    /// One placement row on the Boards tab / All overview.
    struct BoardRow: Equatable, Identifiable {
        let id: String
        let name: String
        /// "CORE · WEEKLY" style badge text, or nil.
        var badge: String? = nil
        /// "This week · ends Sun · 2 days left" / "Oct 5–11 · expired".
        var caption: String
        /// "12" (+ `valueSub` "/20"), "Done", "Not yet", or nil.
        var value: String? = nil
        var valueSub: String? = nil
        var isDone = false
        var isDraft = false
        /// Ring fill 0…1 for the 24pt progress ring.
        var fraction: Double = 0
    }

    struct Link: Equatable, Identifiable {
        let id: String
        let title: String
        let kind: RisoTaskKind
        var isDone = false
        var meta: String? = nil
    }

    struct Template: Equatable, Identifiable {
        let id: String
        let name: String
    }

    /// One Activity row as drawn.
    struct ActivityLine: Equatable, Identifiable {
        let id: String
        let kind: TaskDetailKernel.ActivityKind
        let text: String
        /// "Oct 15" / "Sep 2, 2026".
        let when: String
    }

    let taskId: String
    let title: String
    var description: String? = nil
    let kind: RisoTaskKind
    /// "Counting · linked counter" — drawn uppercase.
    let kicker: String
    /// The anchor board's display name ("Week 42"); nil with no anchor.
    var anchorName: String? = nil
    var anchorTimeframe: Timeframe? = nil
    let hero: Hero
    /// The counter row under the hero (shared counter / counts toward).
    var counter: CounterLink? = nil
    /// ⋯ › "Use as shared counter" is offered (a plain counting task — `canPromoteToCounter`).
    var canPromoteToCounter = false
    var activeBoards: [BoardRow] = []
    var pastBoards: [BoardRow] = []
    var parents: [Link] = []
    var subtasks: [Link] = []
    /// "all of 3" — the compound's completion rule.
    var subtaskRule: String? = nil
    /// The achievement's "Watches" card.
    var watches: Link? = nil
    var watchesHeading: String = "Watches board"
    var watchesMeta: String? = nil
    var watchedBoardId: String? = nil
    var templates: [Template] = []
    var activity: [ActivityLine] = []
    /// "Completed 3× all-time · updated 2d ago".
    var footer: String = ""

    /// The Boards tab's count chip: "Boards · 2" (every board the task reaches).
    var boardCount: Int { activeBoards.count + pastBoards.count }
}

/// Which section the segmented pill shows.
enum TaskDetailTab: Hashable {
    case all, boards, links, activity
}

// MARK: - Pure copy rules

enum TaskDetailFormat {

    /// The hero kicker, derived from real data ("Counting · linked counter",
    /// "Normal · counts toward Books", "Compound · all of 3", "Achievement · first bingo").
    static func kicker(
        task: Task, countKind: CountKind, counterName: String?, ruleLabel: String?
    ) -> String {
        switch task.type {
        case .counting:
            if task.sharedCounterId != nil || task.isCounter == true { return "Counting · linked counter" }
            switch countKind {
            case .duration: return "Counting · duration"
            case .continuous: return "Counting · continuous"
            case .discrete: return "Counting"
            }
        case .normal:
            return counterName.map { "Normal · counts toward \($0)" } ?? "Normal"
        case .compound:
            return ruleLabel.map { "Compound · \($0.lowercased())" } ?? "Compound"
        case .achievement:
            return "Achievement · " + ((task.achievementTrigger ?? .greenlog) == .bingo ? "first bingo" : "greenlog")
        }
    }

    /// "this week" / "today" — the window word for a Normal hero's status pill.
    static func windowWord(_ timeframe: Timeframe?) -> String? {
        switch timeframe {
        case .daily?: return "today"
        case .weekly?: return "this week"
        case .monthly?: return "this month"
        case .yearly?: return "this year"
        default: return nil
        }
    }

    /// The Normal hero's status pill text.
    static func normalStatus(isDone: Bool, timeframe: Timeframe?) -> String {
        if isDone { return "Done" }
        return "Not done" + (windowWord(timeframe).map { " \($0)" } ?? "")
    }

    /// "This week" / "Today" — a placement row's window label.
    static func windowLabel(_ timeframe: Timeframe) -> String {
        switch timeframe {
        case .daily: return "Today"
        case .weekly: return "This week"
        case .monthly: return "This month"
        case .yearly: return "This year"
        case .custom: return "Custom"
        case .indefinite: return "Ongoing"
        }
    }

    /// "Sun" / "Oct 31" — the end day: a weekday inside a week, else month + day.
    static func endDay(_ iso: String, now: Date, timeZone: TimeZone = .current) -> String? {
        guard let end = parseISO8601Date(iso) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = end.timeIntervalSince(now) < 6 * 86_400 ? "EEE" : "MMM d"
        return f.string(from: end)
    }

    /// "Oct 5–11" / "Sep 28 – Oct 4" — a past window's range.
    static func range(start: String, end: String?, timeZone: TimeZone = .current) -> String? {
        guard let s = parseISO8601Date(start) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d"
        let startText = f.string(from: s)
        guard let end, let e = parseISO8601Date(end) else { return startText }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if cal.isDate(s, inSameDayAs: e) { return startText }
        if cal.isDate(s, equalTo: e, toGranularity: .month) {
            f.dateFormat = "d"
            return "\(startText)–\(f.string(from: e))"
        }
        f.dateFormat = "MMM d"
        return "\(startText) – \(f.string(from: e))"
    }

    /// The active row's caption: "This week · ends Sun · 2 days left".
    static func activeCaption(timeframe: Timeframe, endDate: String?, now: Date, timeZone: TimeZone = .current) -> String {
        var parts = [windowLabel(timeframe)]
        if let endDate {
            if let day = endDay(endDate, now: now, timeZone: timeZone) { parts.append("ends \(day)") }
            if let left = SquareSheetFormat.daysLeftText(endDate: endDate, now: now) { parts.append(left) }
        }
        return parts.joined(separator: " · ")
    }

    /// The past / draft row's caption: "Oct 5–11 · expired" / "Custom · not started" (its value sits on the right).
    static func pastCaption(
        isDraft: Bool, timeframe: Timeframe, start: String, end: String?, status: String,
        timeZone: TimeZone = .current
    ) -> String {
        if isDraft { return "\(windowLabel(timeframe)) · not started" }
        var parts: [String] = []
        if let r = range(start: start, end: end, timeZone: timeZone) { parts.append(r) }
        parts.append(status)
        return parts.joined(separator: " · ")
    }

    /// "Oct 15" for this year, "Sep 2, 2026" otherwise.
    static func activityDate(_ iso: String, now: Date, timeZone: TimeZone = .current) -> String {
        guard let d = parseISO8601Date(iso) else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: now)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }

    /// "Completed 3× all-time · updated 2d ago".
    static func footer(completions: Int, updatedAt: String, now: Date) -> String {
        var text = "Completed \(completions)× all-time"
        if let rel = RelativeTime.formatRelativeTime(updatedAt, now: now) { text += " · updated \(rel)" }
        return text
    }
}
