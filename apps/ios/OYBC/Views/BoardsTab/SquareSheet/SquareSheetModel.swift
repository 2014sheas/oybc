import Foundation

// MARK: - SquareSheetModel

/// The square sheet's inputs and its pure copy rules (docs/TASK_DETAIL_REDESIGN.md
/// §Square sheet). The presenter (`BoardPlayView+SquareSheet.swift`) builds a
/// `SquareSheetContent` from the live view model; the views render it with no
/// database, so every state is snapshot-testable. Web twin:
/// `components/boardPlay/squareSheet/squareSheetModel.ts`.
struct SquareSheetContent: Equatable {

    /// One compound child row.
    struct Child: Equatable, Identifiable {
        let id: String
        let title: String
        let kind: RisoTaskKind
        let isDone: Bool
        /// A done child whose only completions are sealed-window-immune cannot be un-done.
        var sealBlocked: Bool = false
        /// A counting child: its box is a `+` that unfolds the chips inline.
        var counting: ChildCount? = nil
    }

    /// A counting child's windowed progress on this board.
    struct ChildCount: Equatable {
        let current: CountValue
        let goal: CountValue
        let unit: String
        let kind: CountKind
        let chips: [CounterLogAmount.TapChip]

        /// "12 / 20" (duration "4h 30m / 10h 30m").
        var meta: String { "\(formatCount(current, kind: kind)) / \(formatCount(goal, kind: kind))" }
    }

    struct Compound: Equatable {
        let children: [Child]
        let isComplete: Bool
        var doneCount: Int { children.filter(\.isDone).count }
    }

    struct Achievement: Equatable {
        /// The watched board / template name; nil when it no longer resolves.
        let watchedName: String?
        /// "MONTHLY" / "CORE · MONTHLY"; nil for a template watcher.
        let timeframeBadge: String?
        let daysLeft: String?
        /// "0 / 1 bingo", "Greenlog" or "‹met› / ‹required›".
        let progress: String
        let isMet: Bool
        /// The watched board id the "Open ‹board›" button routes to; nil hides it.
        let openBoardId: String?
    }

    enum Body: Equatable {
        case normal(isDone: Bool, sealBlocked: Bool)
        case counting(ChildCount)
        case compound(Compound)
        case achievement(Achievement)
    }

    /// A closed (sealed) board: read-only, one "Late log…".
    struct Closed: Equatable {
        /// "Closed Oct 11".
        let lockText: String
        let canLateLog: Bool
    }

    let boardTaskId: String
    let taskId: String
    let title: String
    let kind: RisoTaskKind
    /// The board name every progress line names ("Week 42").
    let boardName: String
    var closed: Closed? = nil
    /// A write is in flight: controls disable (45%, no shadow) but never hide.
    var isBusy: Bool = false
    let body: Body
}

/// The undo recipe for one sheet log.
enum SquareLogUndo: Equatable {
    /// A shared counter: reverse the counter's last log entry.
    case counterLog(sourceTaskId: String)
    /// A standalone count on a placement: restore the windowed count it started from.
    case restoreCount(taskId: String, boardTaskId: String, count: CountValue)
    /// A standalone counting child not placed on this board: apply the inverse delta.
    case childDelta(taskId: String, delta: CountValue)
    /// A compound child toggle: restore the completed state it had before.
    case restoreToggle(taskId: String, wasDone: Bool)
    /// A Normal square toggle (Task Detail's hero): restore its prior completed state.
    case restoreNormal(boardTaskId: String, wasDone: Bool)
}

/// The strip shown under the chips after a log. `scopeTaskId` is the task that
/// was logged (the square's own, or a compound child's) so the strip renders
/// only where it belongs.
struct SquareLogStrip: Equatable {
    let boardTaskId: String
    let scopeTaskId: String
    let text: String
    let undo: SquareLogUndo

    /// The strip a write leaves behind: the new one when the write started, else
    /// none — a stale strip must never outlive a write that replaced its context
    /// (a shared-counter Undo reverses the counter's LATEST log).
    static func afterWrite(started: Bool, _ strip: SquareLogStrip) -> SquareLogStrip? {
        started ? strip : nil
    }

    /// Whether this strip renders for `scopeTaskId` on `boardTaskId`.
    func isVisible(boardTaskId: String, scopeTaskId: String) -> Bool {
        self.boardTaskId == boardTaskId && self.scopeTaskId == scopeTaskId
    }
}

/// What a cross-board credit toast does to the toast already showing.
enum CreditToastAction: Equatable {
    case ignore
    /// A Normal toggle's toast appends the credited counter to its second line.
    case augmentNormal
    case replace

    /// - Parameters:
    ///   - sheetOpen: A square sheet is up (it carries its own strip).
    ///   - showing: The toast on screen, if any.
    ///   - creditedTaskId: The task whose write the credit payload reports (`.uncomplete`), if any.
    static func resolve(sheetOpen: Bool, showing: CreditToastState?, creditedTaskId: String?) -> CreditToastAction {
        if sheetOpen { return .ignore }
        if let showing, let placement = showing.retoggle, let creditedTaskId, creditedTaskId == placement.taskId { return .augmentNormal }
        // A hold-menu write's toast must keep its Undo reversing exactly that write.
        if showing?.squareUndo != nil { return .ignore }
        return .replace
    }
}

/// Copy and small derivations shared by the sheet views and the presenter.
enum SquareSheetFormat {

    /// "/ 20 pages · Week 42" (duration drops the unit).
    static func countLine(goal: CountValue, unit: String, kind: CountKind, board: String) -> String {
        "/ \(formatCount(goal, kind: kind))\(countUnitSuffix(kind, unit: unit)) · \(board)"
    }

    /// "8 to go · Week 42"; nil once the goal is met (or there is none).
    static func restLine(current: CountValue, goal: CountValue, kind: CountKind, board: String) -> String? {
        let rest = goal - current
        guard goal > 0, rest > 0 else { return nil }
        return "\(formatCount(rest, kind: kind)) to go · \(board)"
    }

    /// The hero count's size: duration ("4h 30m") shrinks so it stays on one line.
    static func heroCountSize(_ kind: CountKind) -> CGFloat { kind == .duration ? 40 : 52 }

    /// The sheet's status pill for a count: none at 0, DONE at the goal.
    static func countStatus(current: CountValue, goal: CountValue) -> RisoStatusPill.Status? {
        if goal > 0, current >= goal { return .done }
        return current > 0 ? .inProgress : nil
    }

    /// The sheet's status pill for a compound.
    static func compoundStatus(doneCount: Int, isComplete: Bool) -> RisoStatusPill.Status? {
        if isComplete { return .done }
        return doneCount > 0 ? .inProgress : nil
    }

    /// "of 3 sub-tasks · Week 42".
    static func subtaskLine(total: Int, board: String) -> String {
        "of \(total) sub-task\(total == 1 ? "" : "s") · \(board)"
    }

    /// The UndoStrip line after a log: "Logged +5 pages · Week 42" / "Removed 5 pages · Week 42".
    static func logText(amount: CountValue, kind: CountKind, unit: String, board: String, removed: Bool) -> String {
        let a = formatCountWithUnit(amount, kind: kind, unit: unit)
        return (removed ? "Removed \(a)" : "Logged +\(a)") + " · \(board)"
    }

    /// The Undo strip after a compound child toggle: "Drink water · done" / "· not done".
    static func toggleText(title: String, nowDone: Bool) -> String { "\(title) · \(nowDone ? "done" : "not done")" }

    /// "Closed Oct 11" from a sealed board's `sealedAt`; plain "Closed" when unparseable.
    static func closedText(sealedAt: String?, locale: Locale = Locale(identifier: "en_US_POSIX"), timeZone: TimeZone = .current) -> String {
        guard let sealedAt, let date = parseISO8601Date(sealedAt) else { return "Closed" }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = "MMM d"
        return "Closed \(f.string(from: date))"
    }

    /// "14 days left" / "1 day left" / "Last day"; nil when open-ended, unparseable or past.
    static func daysLeftText(endDate: String?, now: Date = Date()) -> String? {
        guard let endDate, let end = parseISO8601Date(endDate), end >= now else { return nil }
        let secs = end.timeIntervalSince(now)
        if secs < 86_400 { return "Last day" }
        let days = Int(ceil(secs / 86_400))
        return "\(days) day\(days == 1 ? "" : "s") left"
    }

    /// The a11y label of a compound child's checklist box.
    static func childBoxLabel(_ child: SquareSheetContent.Child, isOpen: Bool) -> String {
        if child.counting != nil { return "\(isOpen ? "Hide" : "Log on") \(child.title)" }
        return "\(child.isDone ? "Undo " : "Complete ")\(child.title)"
    }
}
