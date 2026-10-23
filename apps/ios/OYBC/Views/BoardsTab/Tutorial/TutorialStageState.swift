import Foundation

// MARK: - Outcome

/// What applying an event to a lesson state did.
enum TutorialOutcome: Equatable {
    /// The event meant nothing at this step.
    case ignored
    /// The state changed; the step stays (a field typed, a toggle flipped).
    case stayed
    /// The step's action happened: move to the next step.
    case advanced
    /// The lesson's last action happened; `exit` is where the stage lands
    /// (nil = show the complete card).
    case completed(exit: TutorialExit?)
    /// Lesson 1: write this real task before anything else (then the state
    /// has already recorded the add).
    case writes(TutorialWrite)
}

/// A real write lesson 1 asks the coordinator for.
enum TutorialWrite: Equatable {
    /// A Simple task with this title.
    case simple(title: String)
    /// A Discrete Counting task: verb · goal · unit (title derived).
    case counting(verb: String, goal: Int, unit: String)
}

// MARK: - Stage state

/// The running lesson's fixture state: what the facsimiles show, which controls
/// are wired at the current step, and how events move it. Pure value type so
/// every transition unit-tests; `implied(step:)` rebuilds it on resume.
enum TutorialStageState: Equatable {
    case createTask(TutorialCreateTaskState)
    case createBoard(TutorialCreateBoardState)
    case completeBoard(TutorialCompleteBoardState)

    /// A lesson's state at the start of `step`, as the steps before it imply
    /// (`typed` restores what the person entered before leaving).
    static func implied(lesson: TutorialLessonID, step: Int, typed: [String: String] = [:]) -> TutorialStageState? {
        switch lesson {
        case .createTask: return .createTask(.implied(step: step, typed: typed))
        case .createBoard: return .createBoard(.implied(step: step, typed: typed))
        case .completeBoard: return .completeBoard(.implied(step: step))
        default: return nil
        }
    }

    /// The controls lit at `step`.
    func spots(step: Int) -> [TutorialSpot] {
        switch self {
        case .createTask(let s): return s.spots(step: step)
        case .createBoard(let s): return s.spots(step: step)
        case .completeBoard(let s): return s.spots(step: step)
        }
    }

    /// A line that replaces the step's copy once the state moved within the
    /// step (lesson 2's "Eight of eight. Tap Next.").
    func textOverride(step: Int) -> String? {
        if case .createBoard(let s) = self { return s.textOverride(step: step) }
        return nil
    }

    /// The scrim and coach mark step aside (a shipped moment plays whole).
    var coachHidden: Bool {
        if case .completeBoard(let s) = self { return s.moment != nil }
        return false
    }

    /// The text the person typed, for the resume cache.
    var typed: [String: String] {
        switch self {
        case .createTask(let s): return s.typed
        case .createBoard(let s): return s.typed
        case .completeBoard: return [:]
        }
    }

    /// Applies an event at `step`.
    mutating func apply(_ event: TutorialEvent, step: Int) -> TutorialOutcome {
        switch self {
        case .createTask(var s):
            let outcome = s.apply(event, step: step)
            self = .createTask(s)
            return outcome
        case .createBoard(var s):
            let outcome = s.apply(event, step: step)
            self = .createBoard(s)
            return outcome
        case .completeBoard(var s):
            let outcome = s.apply(event, step: step)
            self = .completeBoard(s)
            return outcome
        }
    }
}

// MARK: - Lesson 1 · Create a task

/// The Tasks facsimile + New task sheet facsimile. Steps: + · quick add ·
/// Special type · verb · goal · unit · Add to library.
struct TutorialCreateTaskState: Equatable {
    enum Step {
        static let plus = 0, quickAdd = 1, special = 2, verb = 3, goal = 4, unit = 5, submit = 6
    }

    var sheetOpen = false
    var quickText = ""
    /// The Simple task written at step 2 (the "In your library" row).
    var addedTitle: String?
    var panelOpen = false
    var verb = ""
    var goal = ""
    var unit = ""
    /// The Counting task written at step 7.
    var countingTitle: String?

    static let verbDefault = "Read", goalDefault = "20", unitDefault = "pages"

    /// The goal as a positive whole number, or nil.
    var goalValue: Int? {
        let trimmed = goal.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    var trimmedVerb: String { verb.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUnit: String { unit.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedQuick: String { quickText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The derived title ("Read 20 pages") once all three are filled, else nil.
    var derivedTitle: String? {
        guard !trimmedVerb.isEmpty, let goalValue, !trimmedUnit.isEmpty else { return nil }
        return TaskTitle.generateCounterTaskTitle(action: trimmedVerb, maxCount: CountValue(goalValue), unit: trimmedUnit, countKind: .discrete)
    }

    var canAddToLibrary: Bool { derivedTitle != nil }

    static func implied(step: Int, typed: [String: String]) -> TutorialCreateTaskState {
        var s = TutorialCreateTaskState()
        s.sheetOpen = step >= Step.quickAdd
        s.addedTitle = step >= Step.special ? typed[TutorialField.quickAdd.rawValue] : nil
        s.panelOpen = step >= Step.verb
        // A field the person already passed shows the spec's example when
        // nothing was typed; the field being filled keeps what was typed so far.
        if step >= Step.verb { s.verb = typed[TutorialField.verb.rawValue] ?? (step > Step.verb ? verbDefault : "") }
        if step >= Step.goal { s.goal = typed[TutorialField.goal.rawValue] ?? (step > Step.goal ? goalDefault : "") }
        if step >= Step.unit { s.unit = typed[TutorialField.unit.rawValue] ?? (step > Step.unit ? unitDefault : "") }
        return s
    }

    var typed: [String: String] {
        var t: [String: String] = [:]
        if let addedTitle { t[TutorialField.quickAdd.rawValue] = addedTitle }
        if !trimmedVerb.isEmpty { t[TutorialField.verb.rawValue] = verb }
        if goalValue != nil { t[TutorialField.goal.rawValue] = goal }
        if !trimmedUnit.isEmpty { t[TutorialField.unit.rawValue] = unit }
        return t
    }

    func spots(step: Int) -> [TutorialSpot] {
        switch step {
        case Step.plus: return [.init(id: .tasksPlus)]
        case Step.quickAdd: return [.init(id: .quickAddRow)]
        case Step.special: return [.init(id: .specialTypeButton)]
        case Step.verb: return [.init(id: .verbField)]
        case Step.goal: return [.init(id: .goalField), .init(id: .verbField, ringed: false)]
        case Step.unit: return [.init(id: .unitField), .init(id: .verbField, ringed: false), .init(id: .goalField, ringed: false)]
        case Step.submit:
            return [.init(id: .addToLibrary), .init(id: .verbField, ringed: false), .init(id: .goalField, ringed: false), .init(id: .unitField, ringed: false)]
        default: return []
        }
    }

    mutating func apply(_ event: TutorialEvent, step: Int) -> TutorialOutcome {
        switch (event, step) {
        case (.plusTapped, Step.plus):
            sheetOpen = true
            return .advanced
        case (.typed(.quickAdd, let text), Step.quickAdd):
            quickText = text
            return .stayed
        case (.quickAddSubmitted, Step.quickAdd), (.fieldSubmitted(.quickAdd), Step.quickAdd):
            let title = trimmedQuick
            guard !title.isEmpty else { return .ignored }
            addedTitle = title
            quickText = ""
            return .writes(.simple(title: title))
        case (.specialTapped, Step.special):
            panelOpen = true
            return .advanced
        case (.typed(.verb, let text), let s) where s >= Step.verb:
            verb = text
            return .stayed
        case (.typed(.goal, let text), let s) where s >= Step.goal:
            goal = text
            return .stayed
        case (.typed(.unit, let text), let s) where s >= Step.unit:
            unit = text
            return .stayed
        case (.fieldSubmitted(.verb), Step.verb):
            return trimmedVerb.isEmpty ? .ignored : .advanced
        case (.fieldSubmitted(.goal), Step.goal):
            return goalValue == nil ? .ignored : .advanced
        case (.fieldSubmitted(.unit), Step.unit):
            return trimmedUnit.isEmpty ? .ignored : .advanced
        case (.addToLibraryTapped, Step.submit), (.fieldSubmitted(.unit), Step.submit):
            guard let title = derivedTitle, let goalValue else { return .ignored }
            countingTitle = title
            return .writes(.counting(verb: trimmedVerb, goal: goalValue, unit: trimmedUnit))
        default:
            return .ignored
        }
    }
}

// MARK: - Lesson 2 · Create a board

/// The Create hub, the wizard (Setup · Tasks · Preview) and the source sheet,
/// over the Fitness fixture. No writes; the hand-added task belongs to the
/// fixture and is dropped with it.
struct TutorialCreateBoardState: Equatable {
    enum Step {
        static let hub = 0, timeframe = 1, size = 2, addFromPool = 3, pickPool = 4, sourceRow = 5, exclude = 6, handAdd = 7, activate = 8
    }

    enum Screen: Equatable { case hub, setup, tasks, preview }

    var screen: Screen = .hub
    var timeframePicked = false
    var sizePicked = false
    var sourceSheetOpen = false
    /// Fitness is checked on the source sheet.
    var poolChecked = false
    /// Fitness is a source row on the Tasks step.
    var poolAdded = false
    var sourceExpanded = false
    var excluded = false
    var quickText = ""
    var handAddedTitle: String?

    var trimmedQuick: String { quickText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The pool header's count: the pool's live tasks plus the hand-added one.
    var poolCount: Int {
        (poolAdded ? TutorialCreateBoardFixture.fitness.count - (excluded ? 1 : 0) : 0) + (handAddedTitle == nil ? 0 : 1)
    }

    var satisfied: Bool { poolCount >= TutorialCreateBoardFixture.required }

    /// "8 tasks" / "8 tasks · 1 excluded" under the source row.
    var sourceSubtitle: String {
        let n = TutorialCreateBoardFixture.fitness.count
        return excluded ? "\(n) tasks · 1 excluded" : "\(n) tasks"
    }

    static func implied(step: Int, typed: [String: String]) -> TutorialCreateBoardState {
        var s = TutorialCreateBoardState()
        switch step {
        case Step.hub: s.screen = .hub
        case Step.timeframe, Step.size: s.screen = .setup
        case Step.activate: s.screen = .preview
        default: s.screen = .tasks
        }
        s.timeframePicked = step >= Step.size
        s.sizePicked = step > Step.size
        s.sourceSheetOpen = step == Step.pickPool
        s.poolAdded = step >= Step.sourceRow
        s.sourceExpanded = step == Step.exclude
        s.excluded = step >= Step.handAdd
        // Added at step 8 (before its Next) or implied by step 9.
        if step >= Step.handAdd, let title = typed[TutorialField.wizardQuickAdd.rawValue] {
            s.handAddedTitle = title
        } else if step >= Step.activate {
            s.handAddedTitle = TutorialCreateBoardFixture.handAddedDefault
        }
        return s
    }

    var typed: [String: String] {
        guard let handAddedTitle else { return [:] }
        return [TutorialField.wizardQuickAdd.rawValue: handAddedTitle]
    }

    func spots(step: Int) -> [TutorialSpot] {
        switch step {
        case Step.hub: return [.init(id: .oneOffCard)]
        case Step.timeframe: return [.init(id: .timeframeWeekly)]
        case Step.size: return sizePicked ? [.init(id: .setupNext), .init(id: .sizeCard3, ringed: false)] : [.init(id: .sizeCard3)]
        case Step.addFromPool: return [.init(id: .addFromPool)]
        case Step.pickPool:
            let row = TutorialSpot(id: .poolRow(TutorialCreateBoardFixture.livePool))
            return poolChecked ? [.init(id: .sourcesDone), .init(id: row.id, ringed: false)] : [row]
        case Step.sourceRow: return [.init(id: .sourceRow)]
        case Step.exclude: return [.init(id: .memberExclude(TutorialCreateBoardFixture.excludedTitle))]
        case Step.handAdd: return handAddedTitle == nil ? [.init(id: .wizardQuickRow)] : [.init(id: .tasksNext)]
        case Step.activate: return [.init(id: .activate)]
        default: return []
        }
    }

    func textOverride(step: Int) -> String? {
        step == Step.handAdd && handAddedTitle != nil ? TutorialCatalog.createBoardNextText : nil
    }

    mutating func apply(_ event: TutorialEvent, step: Int) -> TutorialOutcome {
        switch (event, step) {
        case (.oneOffTapped, Step.hub):
            screen = .setup
            return .advanced
        case (.weeklyTapped, Step.timeframe):
            timeframePicked = true
            return .advanced
        case (.size3Tapped, Step.size):
            sizePicked = true
            return .stayed
        case (.setupNextTapped, Step.size):
            guard sizePicked else { return .ignored }
            screen = .tasks
            return .advanced
        case (.addFromPoolTapped, Step.addFromPool):
            sourceSheetOpen = true
            return .advanced
        case (.poolToggled(let name), Step.pickPool) where name == TutorialCreateBoardFixture.livePool:
            poolChecked.toggle()
            return .stayed
        case (.sourcesDoneTapped, Step.pickPool):
            guard poolChecked else { return .ignored }
            sourceSheetOpen = false
            poolAdded = true
            return .advanced
        case (.sourceRowTapped, Step.sourceRow):
            sourceExpanded = true
            return .advanced
        case (.memberExcluded(let title), Step.exclude) where title == TutorialCreateBoardFixture.excludedTitle:
            excluded = true
            // The stage collapses the panel and scrolls back up.
            sourceExpanded = false
            return .advanced
        case (.typed(.wizardQuickAdd, let text), Step.handAdd):
            quickText = text
            return .stayed
        case (.wizardQuickSubmitted, Step.handAdd), (.fieldSubmitted(.wizardQuickAdd), Step.handAdd):
            guard handAddedTitle == nil, !trimmedQuick.isEmpty else { return .ignored }
            handAddedTitle = trimmedQuick
            quickText = ""
            return .stayed
        case (.tasksNextTapped, Step.handAdd):
            guard satisfied else { return .ignored }
            screen = .preview
            return .advanced
        case (.activateTapped, Step.activate):
            return .completed(exit: nil)
        default:
            return .ignored
        }
    }
}

// MARK: - Lesson 3 · Complete a board

/// The Sample week play board with its Edit panel, replace sheet, square sheet
/// and hold menu. No writes.
struct TutorialCompleteBoardState: Equatable {
    enum Step {
        static let edit = 0, tapJournal = 1, pickReplacement = 2, save = 3, tapStretch = 4, toast = 5
        static let tapRead = 6, chips = 7, undoStrip = 8, holdTidy = 9, markDone = 10, finale = 11
    }

    enum Moment: Equatable { case bingo, greenlog }

    var editing = false
    var replaceSheetOpen = false
    /// Journal reads Meditate 5 min.
    var swapped = false
    var done: Set<Int> = TutorialSampleWeek.initiallyDone
    var readCount = TutorialSampleWeek.grid[TutorialSampleWeek.Slot.read].count
    var toastVisible = false
    var squareSheetOpen = false
    var undoText: String?
    var holdMenuOpen = false
    /// A shipped moment is on screen (under the bar, no scrim).
    var moment: Moment?
    /// The Bingo played; later lines ring gold with no moment.
    var bingoPlayed = false

    static let undoLine = "Logged +\(TutorialSampleWeek.chip) pages · \(TutorialSampleWeek.boardName)"

    var readGoal: Int { TutorialSampleWeek.grid[TutorialSampleWeek.Slot.read].goal ?? 20 }
    var completedCount: Int { done.count }
    var completeLines: [[Int]] { TutorialSampleWeek.completeLines(done) }
    /// Slots on a complete line (the gold ring).
    var ringedSlots: Set<Int> { Set(completeLines.flatMap { $0 }) }
    /// Edit's footer: pending changes.
    var changeCount: Int { editing && swapped ? 1 : 0 }
    /// The finale's squares still open.
    var remaining: [Int] { TutorialSampleWeek.grid.indices.filter { !done.contains($0) } }

    /// A square's title as shown now.
    func title(at slot: Int) -> String {
        slot == TutorialSampleWeek.Slot.journal && swapped ? TutorialSampleWeek.replacement : TutorialSampleWeek.grid[slot].title
    }

    static func implied(step: Int) -> TutorialCompleteBoardState {
        var s = TutorialCompleteBoardState()
        s.editing = (Step.tapJournal...Step.save).contains(step)
        s.replaceSheetOpen = step == Step.pickReplacement
        s.swapped = step >= Step.save
        if step >= Step.toast { s.done.insert(TutorialSampleWeek.Slot.stretch) }
        if step >= Step.undoStrip {
            s.done.insert(TutorialSampleWeek.Slot.read)
            s.readCount = TutorialSampleWeek.grid[TutorialSampleWeek.Slot.read].count + 2 * TutorialSampleWeek.chip
        }
        if step >= Step.finale {
            s.done.insert(TutorialSampleWeek.Slot.tidy)
            s.bingoPlayed = true
        }
        s.toastVisible = step == Step.toast
        s.squareSheetOpen = step == Step.chips || step == Step.undoStrip
        s.undoText = step == Step.undoStrip ? undoLine : nil
        s.holdMenuOpen = step == Step.markDone
        return s
    }

    func spots(step: Int) -> [TutorialSpot] {
        guard moment == nil else { return [] }
        switch step {
        case Step.edit: return [.init(id: .editButton)]
        case Step.tapJournal: return [.init(id: .editSquare(TutorialSampleWeek.Slot.journal))]
        case Step.pickReplacement: return [.init(id: .replaceRow(TutorialSampleWeek.replacement))]
        case Step.save: return [.init(id: .saveChanges)]
        case Step.tapStretch: return [.init(id: .square(TutorialSampleWeek.Slot.stretch))]
        case Step.toast: return [.init(id: .undoToast)]
        case Step.tapRead: return [.init(id: .square(TutorialSampleWeek.Slot.read))]
        case Step.chips: return [.init(id: .chip(TutorialSampleWeek.chip))]
        case Step.undoStrip: return [.init(id: .undoStrip)]
        case Step.holdTidy: return [.init(id: .square(TutorialSampleWeek.Slot.tidy))]
        case Step.markDone: return [.init(id: .markDone)]
        case Step.finale: return remaining.map { .init(id: .square($0)) }
        default: return []
        }
    }

    mutating func apply(_ event: TutorialEvent, step: Int) -> TutorialOutcome {
        // The moments' buttons work at any step they can show.
        switch event {
        case .momentBackTapped:
            guard let open = moment else { return .ignored }
            moment = nil
            return open == .greenlog ? .completed(exit: nil) : .stayed
        case .momentNewBoardTapped:
            guard moment == .greenlog else { return .ignored }
            moment = nil
            return .completed(exit: .create)
        default:
            break
        }
        guard moment == nil else { return .ignored }
        switch (event, step) {
        case (.editTapped, Step.edit):
            editing = true
            return .advanced
        case (.editSquareTapped(let slot), Step.tapJournal) where slot == TutorialSampleWeek.Slot.journal:
            replaceSheetOpen = true
            return .advanced
        case (.replaceRowTapped(let title), Step.pickReplacement) where title == TutorialSampleWeek.replacement:
            replaceSheetOpen = false
            swapped = true
            return .advanced
        case (.saveTapped, Step.save):
            editing = false
            return .advanced
        case (.squareTapped(let slot), Step.tapStretch) where slot == TutorialSampleWeek.Slot.stretch:
            done.insert(slot)
            toastVisible = true
            return .advanced
        case (.nextTapped, Step.toast):
            toastVisible = false
            return .advanced
        case (.squareTapped(let slot), Step.tapRead) where slot == TutorialSampleWeek.Slot.read:
            squareSheetOpen = true
            return .advanced
        case (.chipTapped(let amount), Step.chips) where amount == TutorialSampleWeek.chip:
            readCount += amount
            undoText = Self.undoLine
            guard readCount >= readGoal else { return .stayed }
            done.insert(TutorialSampleWeek.Slot.read)
            return .advanced
        case (.nextTapped, Step.undoStrip):
            squareSheetOpen = false
            undoText = nil
            return .advanced
        case (.squareHeld(let slot), Step.holdTidy) where slot == TutorialSampleWeek.Slot.tidy:
            holdMenuOpen = true
            return .advanced
        case (.markDoneTapped, Step.markDone):
            holdMenuOpen = false
            done.insert(TutorialSampleWeek.Slot.tidy)
            moment = .bingo
            bingoPlayed = true
            return .advanced
        case (.squareTapped(let slot), Step.finale) where remaining.contains(slot):
            done.insert(slot)
            if remaining.isEmpty { moment = .greenlog }
            return .stayed
        default:
            return .ignored
        }
    }
}
