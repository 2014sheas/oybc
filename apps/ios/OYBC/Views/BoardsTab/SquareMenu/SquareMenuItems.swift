import Foundation

// MARK: - SquareMenuItems

/// What a menu item does. The presenter (`BoardPlayView+SquareMenu.swift`) maps each
/// case to a write, a sheet or a navigation.
enum SquareMenuAction: Equatable {
    case toggleNormal
    case log(CountValue)
    case logOther
    case remove
    case completeNextSubtask(childId: String)
    case logChild(childId: String, amount: CountValue)
    case allSubtasks
    case openBoard(String)
    case lateLog
    case details
    case openLibrary
}

/// One menu row. The first item is the type's primary action (gold on web).
struct SquareMenuItem: Equatable {
    let action: SquareMenuAction
    let label: String
    var meta: String? = nil
    let icon: String
    var isPrimary = false
    /// A write the busy flag disables (a sheet / navigation item is never a write).
    var isWrite = false
    var isEnabled = true
}

enum SquareMenuEntry: Equatable {
    case item(SquareMenuItem)
    case divider
}

/// The type-specific facts the pure builder needs — assembled by the presenter.
struct SquareMenuInput {
    struct Counting {
        let kind: CountKind
        let unit: String
        let current: CountValue
        let goal: CountValue
        /// The counter's remembered amount (shared source for discrete, the task's own otherwise).
        let rememberedDefault: CountValue?
    }
    struct Compound {
        /// The `TaskDetailKernel.nextSubtask` pick; nil when nothing is open.
        let next: TaskDetailKernel.SubtaskAction?
        let nextChildTitle: String?
        /// The picked counting child's own kind / unit / remembered default (for "Log +‹quick› · ‹child›").
        let nextChild: Counting?
        let doneCount: Int
        let total: Int
    }
    enum Body {
        case normal(isDone: Bool, sealBlocked: Bool)
        case counting(Counting)
        case compound(Compound)
        /// `watchedName` / `openBoardId` are nil for a template watcher.
        case achievement(isMet: Bool, watchedName: String?, openBoardId: String?)
    }

    let title: String
    let kind: RisoTaskKind
    var body: Body
    var isClosed = false
    var lateLogRoutable = false
    /// Writes render disabled. The items are system-drawn, so this IS the menu's busy look:
    /// the caller passes the delayed look (`BusyLook.delay`); the actions re-check the real
    /// in-flight flag themselves.
    var isBusy = false
}

/// The unified hold-menu vocabulary (docs/TASK_DETAIL_REDESIGN.md §PR 3). Pure, so
/// one unit test pins every type and the closed-board collapse. Web twin:
/// `components/boardPlay/squareMenu/squareMenuItems.ts` — keep the strings identical.
enum SquareMenu {

    /// Whether a done Normal square's un-complete is inert — read from the precomputed
    /// set (the menu never touches the database while it builds).
    static func sealBlocked(isDone: Bool, isClosed: Bool, taskId: String, cached: Set<String>) -> Bool {
        isDone && !isClosed && cached.contains(taskId)
    }

    /// The quick log amount: remembered default first, else 1 / the first FIXED preset.
    static func quickAmount(_ c: SquareMenuInput.Counting) -> CountValue {
        CounterLogAmount.quickAmount(kind: c.kind, chips: CounterLogAmount.hubChips(kind: c.kind), defaultLogAmount: c.rememberedDefault)
    }

    /// The first FIXED preset above the quick amount; nil when none (omit the item).
    static func nextPreset(above amount: CountValue, kind: CountKind) -> CountValue? {
        CounterLogAmount.fixedChipAmounts(kind).sorted().first { $0 > amount }
    }

    /// "pages", "mi" — the unit noun for "Remove pages…"; nil for duration or blank.
    private static func unitNoun(_ kind: CountKind, _ unit: String) -> String? {
        let suffix = countUnitSuffix(kind, unit: unit).trimmingCharacters(in: .whitespaces)
        return suffix.isEmpty ? nil : suffix
    }

    /// "Log +5 pages".
    static func logLabel(_ amount: CountValue, kind: CountKind, unit: String) -> String {
        "Log +" + formatCountWithUnit(amount, kind: kind, unit: unit)
    }

    /// The header's meta: "12 / 20", "2 / 3", "Not done", "Watching".
    static func meta(_ input: SquareMenuInput) -> String {
        switch input.body {
        case let .normal(isDone, _): return isDone ? "Done" : "Not done"
        case let .counting(c):
            return "\(formatCount(c.current, kind: c.kind)) / \(formatCount(c.goal, kind: c.kind))"
        case let .compound(c): return "\(c.doneCount) / \(c.total)"
        case let .achievement(isMet, _, _): return isMet ? "Done" : "Watching"
        }
    }

    /// "Read 20 pages · 12 / 20" — the menu's header line.
    static func headerText(_ input: SquareMenuInput) -> String { "\(input.title) · \(meta(input))" }

    /// The ordered rows. Closed boards collapse every write item to one "Late log…".
    static func entries(for input: SquareMenuInput) -> [SquareMenuEntry] {
        let details = SquareMenuItem(action: .details, label: "Details", icon: "info.circle")
        let library = SquareMenuItem(action: .openLibrary, label: "Open in library", icon: "book")
        let lateLog = SquareMenuItem(action: .lateLog, label: "Late log…", icon: "lock", isPrimary: true)
        let writesLocked = input.isBusy
        var out: [SquareMenuEntry] = []

        func lead(_ items: [SquareMenuItem]) {
            if input.isClosed {
                if input.lateLogRoutable { out.append(.item(lateLog)) }
            } else {
                out.append(contentsOf: items.map(SquareMenuEntry.item))
            }
        }
        func divider() { if !out.isEmpty, out.last != .divider { out.append(.divider) } }

        switch input.body {
        case let .normal(isDone, sealBlocked):
            lead([SquareMenuItem(
                action: .toggleNormal, label: isDone ? "Mark not done" : "Mark done", icon: isDone ? "xmark.circle" : "checkmark.circle",
                isPrimary: true, isWrite: true, isEnabled: !writesLocked && !(isDone && sealBlocked)
            )])
            divider()
            out.append(.item(details)); out.append(.item(library))

        case let .counting(c):
            let quick = quickAmount(c)
            var items = [SquareMenuItem(
                action: .log(quick), label: logLabel(quick, kind: c.kind, unit: c.unit), icon: "plus",
                isPrimary: true, isWrite: true, isEnabled: !writesLocked
            )]
            if let next = nextPreset(above: quick, kind: c.kind) {
                items.append(SquareMenuItem(
                    action: .log(next), label: logLabel(next, kind: c.kind, unit: c.unit), icon: "plus", isWrite: true, isEnabled: !writesLocked
                ))
            }
            items.append(SquareMenuItem(action: .logOther, label: "Log other amount…", icon: "slider.horizontal.3"))
            lead(items)
            if !input.isClosed {
                divider()
                let noun = unitNoun(c.kind, c.unit)
                out.append(.item(SquareMenuItem(
                    action: .remove, label: noun.map { "Remove \($0)…" } ?? "Remove…", icon: "minus", isEnabled: c.current > 0
                )))
            }
            divider()
            out.append(.item(details)); out.append(.item(library))

        case let .compound(c):
            var items: [SquareMenuItem] = []
            switch c.next {
            case let .toggle(childId):
                items.append(SquareMenuItem(
                    action: .completeNextSubtask(childId: childId), label: "Complete next sub-task", meta: c.nextChildTitle,
                    icon: "checkmark.circle", isPrimary: true, isWrite: true, isEnabled: !writesLocked
                ))
            case let .log(childId):
                if let child = c.nextChild {
                    let quick = quickAmount(child)
                    items.append(SquareMenuItem(
                        action: .logChild(childId: childId, amount: quick),
                        label: logLabel(quick, kind: child.kind, unit: child.unit) + (c.nextChildTitle.map { " · \($0)" } ?? ""),
                        icon: "plus", isPrimary: true, isWrite: true, isEnabled: !writesLocked
                    ))
                }
            case nil: break
            }
            lead(items)
            if input.isClosed { divider() } // "Late log…" stands apart from the read item
            out.append(.item(SquareMenuItem(action: .allSubtasks, label: "All sub-tasks…", meta: "\(c.doneCount) / \(c.total)", icon: "checklist")))
            divider()
            out.append(.item(library))

        case let .achievement(_, watchedName, openBoardId):
            if let openBoardId, let watchedName {
                out.append(.item(SquareMenuItem(action: .openBoard(openBoardId), label: "Open \(watchedName)", icon: "square.grid.3x3", isPrimary: true)))
                divider()
            }
            out.append(.item(details)); out.append(.item(library))
        }
        return out
    }
}
