import SwiftUI

// MARK: - Controls

/// A control a facsimile can wire. The facsimile tags it with
/// `.tutorialWired(_:)`; the stage lights the ones the lesson state names for
/// the current step (`TutorialStageState.spots`), punches a hole in the scrim
/// over each and rings the primary ones in gold. Everything else on the
/// facsimile sits under the scrim.
enum TutorialControlID: Hashable {
    // Lesson 1 — Create a task
    case tasksPlus
    /// The quick-add field + Add button (one control: "a field counts as one").
    case quickAddRow
    case specialTypeButton
    case verbField
    case goalField
    case unitField
    case addToLibrary
    // Lesson 2 — Create a board
    case oneOffCard
    case timeframeWeekly
    /// The Setup step's dashed window chip (lit read-only once Weekly is picked).
    case windowChip
    case sizeCard3
    /// The "8 tasks" caption under the size cards (lit read-only with Next).
    case taskCountLabel
    /// The Center square row, Free selected (lit read-only with Next).
    case centerRow
    case setupNext
    case addFromPool
    /// A pool row on the source sheet, by pool name.
    case poolRow(String)
    case sourcesDone
    /// The pulled pool's source row on the Tasks step (tap expands it).
    case sourceRow
    /// A member row's ✕ inside the expanded pool, by task title.
    case memberExclude(String)
    /// The Tasks step's quick-add field + Add.
    case wizardQuickRow
    case tasksNext
    case activate
    // Lesson 3 — Complete a board
    case editButton
    /// A square in the Edit grid by row-major slot.
    case editSquare(Int)
    /// A row on the replace sheet, by task title.
    case replaceRow(String)
    case saveChanges
    /// A play-board square by row-major slot.
    case square(Int)
    /// The Undo toast after a Simple square completes (lit, inert).
    case undoToast
    /// The square sheet's +N chip.
    case chip(Int)
    /// The square sheet's Undo strip (lit, inert).
    case undoStrip
    /// "Mark done" in the hold menu.
    case markDone
}

/// One lit control: ringed in gold (the step's target) or merely open (a hole
/// with no ring — a field the person already filled stays editable). A ringed
/// spot that is not `primary` is lit for reading only (lesson 2's "8 tasks"
/// caption next to the wired Next); the coach mark's notch points at the
/// primary one when there is exactly one.
struct TutorialSpot: Hashable {
    let id: TutorialControlID
    var ringed: Bool = true
    var primary: Bool = true
}

// MARK: - Events

/// What a facsimile reports when the person uses a wired control. The lesson
/// state decides whether the event moves the step (`TutorialStageState.apply`).
enum TutorialEvent: Equatable {
    /// The coach mark's Next (read-only steps).
    case nextTapped
    /// A wired text field changed (every keystroke, so resume can rebuild it).
    case typed(TutorialField, String)
    /// Return on a wired field (or the number pad's Next).
    case fieldSubmitted(TutorialField)
    // Lesson 1
    case plusTapped
    case quickAddSubmitted
    case specialTapped
    case addToLibraryTapped
    // Lesson 2
    case oneOffTapped
    case weeklyTapped
    case size3Tapped
    case setupNextTapped
    case addFromPoolTapped
    case poolToggled(String)
    case sourcesDoneTapped
    case sourceRowTapped
    case memberExcluded(String)
    case wizardQuickSubmitted
    case tasksNextTapped
    case activateTapped
    // Lesson 3
    case editTapped
    case editSquareTapped(Int)
    case replaceRowTapped(String)
    case saveTapped
    case squareTapped(Int)
    case squareHeld(Int)
    case chipTapped(Int)
    case markDoneTapped
    /// The moment's "Back to board".
    case momentBackTapped
    /// The Greenlog's "Start a new board".
    case momentNewBoardTapped
}

/// A wired text field (its text lives in the lesson state).
enum TutorialField: String, Equatable {
    case quickAdd
    case verb
    case goal
    case unit
    case wizardQuickAdd
}

// MARK: - Steps

/// One walkthrough step: its coach copy (`LESSON_COPY.md`) and how it ends.
/// A compact step has an instruction line and a note (the "why"); a **tell**
/// has a title and a body, shows over the dimmed facsimile with nothing lifted
/// and always ends with Next.
struct TutorialStep: Equatable {
    /// How the step ends.
    enum Advance: Equatable {
        /// The wired control's event (the lesson state decides which).
        case action
        /// The coach mark's Next button (read-only step, or a tell).
        case next
    }

    /// The instruction line (a tell's body).
    let text: String
    let advance: Advance
    /// The note under the instruction: the why, the other options, the page.
    var note: String? = nil
    /// A tell's title; nil for a compact step.
    var title: String? = nil
    /// The short form shown with the RESUMED tag when the lesson reopens here.
    var resumedText: String? = nil

    var isTell: Bool { title != nil }

    /// A compact step the wired control ends.
    static func action(_ text: String, note: String, resumedText: String? = nil) -> TutorialStep {
        TutorialStep(text: text, advance: .action, note: note, resumedText: resumedText)
    }

    /// A read-only step Next ends.
    static func next(_ text: String, note: String) -> TutorialStep {
        TutorialStep(text: text, advance: .next, note: note)
    }

    /// A tell: title + body over the dimmed facsimile, Next ends it.
    static func tell(_ title: String, _ body: String) -> TutorialStep {
        TutorialStep(text: body, advance: .next, title: title)
    }
}

// MARK: - Lesson definitions

/// Static description of one tutorial square: its copy, glyph and (for the free
/// lessons) its script and sheet copy.
struct TutorialLessonInfo: Identifiable {
    let id: TutorialLessonID
    let title: String
    /// SF Symbol for a free lesson's icon tile; nil for Pro placeholders.
    let glyph: String?
    /// The start sheet's one expectation line.
    let startLine: String
    /// The lesson-complete card's second line (lesson 1 fills in the two titles).
    let completeSubtitle: String
    /// The lesson-complete card's plain secondary action, if any.
    let completeSecondary: TutorialExit?
    let steps: [TutorialStep]

    var isFree: Bool { id.isFree }

    /// The tutorial bar's label: "Lesson 1 · Create a task".
    var barLabel: String { "Lesson \(number) · \(title)" }

    /// 1-based number in the free row (0 for a Pro square).
    var number: Int { (TutorialLessonID.middleRow.firstIndex(of: id) ?? -1) + 1 }
}

/// Where the stage lands the person when a lesson closes.
enum TutorialExit: Equatable {
    /// Back on the tutorial board (the square pops).
    case board
    /// The real Tasks tab ("Open Tasks").
    case tasks
    /// The real Create tab ("Open Create" / the Greenlog's "Start a new board").
    case create

    /// The complete card's plain link copy.
    var label: String {
        switch self {
        case .board: return "Back to the board"
        case .tasks: return "Open Tasks"
        case .create: return "Open Create"
        }
    }
}

/// The nine lessons, keyed by grid order.
enum TutorialCatalog {

    /// Lesson info in grid order (row-major).
    static let lessons: [TutorialLessonInfo] = TutorialLessonID.allCases.map(info(for:))

    /// Looks up a lesson.
    static func info(for id: TutorialLessonID) -> TutorialLessonInfo {
        switch id {
        case .multiStep: return pro(id, "Multi-step tasks")
        case .repeatingBoards: return pro(id, "Repeating boards")
        case .mixSources: return pro(id, "Mix your sources")
        case .sharedCounters: return pro(id, "Shared counters")
        case .biggerWindows: return pro(id, "Bigger windows")
        case .achievements: return pro(id, "Achievements")
        case .createTask:
            return TutorialLessonInfo(
                id: id, title: "Create a task", glyph: "list.bullet",
                startLine: "The two tasks you make here are real and stay in your library.",
                completeSubtitle: "Both tasks are in your library.",
                completeSecondary: .tasks,
                steps: createTaskSteps
            )
        case .createBoard:
            return TutorialLessonInfo(
                id: id, title: "Create a board", glyph: "square.grid.3x3",
                startLine: "Runs on a sample board and sample pools. Your own boards are not touched.",
                completeSubtitle: "Nothing was saved to your boards. Make a real one from the Create tab.",
                completeSecondary: .create,
                steps: createBoardSteps
            )
        case .completeBoard:
            return TutorialLessonInfo(
                id: id, title: "Complete a board", glyph: "checkmark",
                startLine: "Runs on a sample board, half played. Your own boards are not touched.",
                completeSubtitle: "A Bingo and a Greenlog on the sample board. Nothing was saved.",
                completeSecondary: nil,
                steps: completeBoardSteps
            )
        }
    }

    /// A Pro placeholder: no script, no glyph.
    private static func pro(_ id: TutorialLessonID, _ title: String) -> TutorialLessonInfo {
        TutorialLessonInfo(id: id, title: title, glyph: nil, startLine: "", completeSubtitle: "", completeSecondary: nil, steps: [])
    }

    /// The nine titles in grid order (the tutorial Greenlog's squares).
    static var titles: [String] { lessons.map(\.title) }

    // MARK: Scripts (`LESSON_COPY.md`, verbatim)

    /// Lesson 1 · Create a task (10 steps, 3 tells) — the Tasks facsimile and
    /// the New task sheet facsimile; the two adds write real tasks.
    static let createTaskSteps: [TutorialStep] = [
        .tell("Your library", "Every task you make is saved here, and boards take their squares from it. One task can sit on many boards."),
        .action("Tap + to add a task.", note: "Search and the filters find tasks you already have."),
        .tell("Two kinds of task", "A Simple task is done with one tap. A Counting task adds up toward a goal, like 20 pages."),
        .action("Type a task, then tap Add.", note: "Quick add makes a Simple task: a title, nothing else. Add keeps the sheet open for more."),
        .action("Tap Counting · Compound · Achievement.", note: "Counting tracks a number. Compound and Achievement are Pro types.", resumedText: "Tap Special type."),
        .tell("Three parts make a counter", "A verb, a goal and a unit make the title: Read 20 pages. You can rename it later."),
        .action("Type the verb, like Read.", note: "Kind sets what you count: whole things, an amount, or time. Discrete fits pages."),
        .action("Type the goal, 20.", note: "The goal completes the square. Logging past it is fine."),
        .action("Type the unit, pages.", note: "A plural noun. The title fills in below from all three."),
        .action("Tap Add to library.", note: "The task is saved and can go on any board."),
    ]

    /// Lesson 2 · Create a board (14 steps, 3 tells) — the Create hub, the
    /// wizard's three steps and the source sheet, all facsimiles over the
    /// Fitness fixture. Step 4's line names the sample week the Setup facsimile
    /// shows (`TutorialCreateBoardFixture.windowLine`).
    static let createBoardSteps: [TutorialStep] = [
        .action("Tap Start a one-off board.", note: "A one-off board runs once and ends. Recurring boards repeat each period; they have their own lesson."),
        .tell("When and how big", "Timeframe sets how long the board runs. Size sets the grid of squares to fill."),
        .action("Tap Weekly.", note: "Daily to Yearly run for the current day, week, month or year. Custom takes your own start and end."),
        .next(TutorialCreateBoardFixture.windowLine, note: "That is its window. Squares can be completed until the week ends; then the board closes as it stands."),
        .action("Tap 3×3.", note: "9, 16 or 25 squares. A Bingo is a full row, column or diagonal, so bigger boards mean longer lines."),
        .action("Tap Next.", note: "Nine squares with a Free centre needs 8 tasks. Choose picks the centre task yourself; None makes it an ordinary square, so 9."),
        .tell("Where squares come from", "Every square holds a task. Type them one at a time, or deal a set from a pool."),
        .action("Tap Add from a pool or board.", note: "The meter counts tasks against the 8 needed. You can also type them one at a time."),
        .action("Tap Fitness, then Done.", note: "A pool is a saved list of tasks you can deal onto any board. Other boards can be a source too."),
        .tell("Tune what a pool deals", "A pool does not have to go on whole. Leave out what does not fit, then fill the gap yourself."),
        .action("Tap Fitness to open it.", note: "A source row shows its task count. Open it to see exactly which tasks it adds."),
        .action("Tap ✕ on Bike to work.", note: "That leaves it off this board only; the pool keeps it. The range above sets how many of the pool to deal."),
        .action("Type a task, then tap Add.", note: "One short. Tasks typed here list under On your board, next to the pool."),
        .action("Tap Activate Board.", note: "Preview is the board as dealt; Rearrange lets you move tasks first. Activate puts it in play."),
    ]

    /// Lesson 2 step 13's second line (13b), once the hand-added task restores 8/8.
    static let createBoardNextStep = TutorialStep.action("Tap Next.", note: "8 of 8. The meter turns green once the board has enough tasks.")

    /// Lesson 3 · Complete a board (16 steps, 3 tells) — the Sample week
    /// facsimile with its Edit panel, replace sheet, square sheet and hold menu;
    /// the shipped moments play the Bingo (its own step) and the Greenlog.
    static let completeBoardSteps: [TutorialStep] = [
        .tell("Reading a board", "Squares done, days left and Bingos sit at the top. Colour is the task type: red is Simple, blue is Counting."),
        .action("Tap Edit.", note: "Edit changes which task sits in a square. Done squares keep their progress."),
        .action("Tap Journal.", note: "Any square can be swapped. Lock, shuffle and the board actions below are the rest of Edit."),
        .action("Pick Meditate 5 min.", note: "Any task in your library can take the square."),
        .action("Tap Save changes.", note: "Swaps apply when you save. Cancel throws them away."),
        .tell("Three ways to play a square", "Tap a Simple square to complete it. Tap a Counting square to log. Press and hold any square for quick actions."),
        .action("Tap Stretch.", note: "Red squares are Simple tasks: one tap and they are done."),
        .next("Done. Undo if you did not mean it.", note: "The toast stays a few seconds, then the square counts as done."),
        .action("Tap Read 20 pages.", note: "Blue squares are Counting tasks, 12 of 20 so far. Tapping opens the log instead of completing it."),
        .action("Tap +5 twice.", note: "Chips add to the count. +8 ✓ is exactly what is left; Other… takes any number."),
        .next("22 of 20. The square is done.", note: "Going past the goal is allowed and counts. Undo takes back the last +5."),
        .action("Press and hold Tidy desk.", note: "A tap would complete it. Holding opens the quick actions instead."),
        .action("Tap Mark done.", note: "Same as a tap, without leaving the menu. Details and Open in library are on every square."),
        .action("Tap Back to board.", note: "The middle row is a Bingo. Share is off in the tutorial."),
        .tell("Lines and the Greenlog", "A full row, column or diagonal is a Bingo. Every square done is a Greenlog."),
        .action("Three left. Tap any of them.", note: "Lines you complete along the way ring gold. The last square is the Greenlog."),
    ]

    /// Lesson 3 step 10's second line (10b), after the first +5.
    static let completeBoardSecondChipStep = TutorialStep.action("Tap +5 once more.", note: "17 of 20. Undo under the chips takes back the last log.")

    /// Lesson 3 step 16's line over the Greenlog moment (16c).
    static let completeBoardGreenlogStep = TutorialStep.action("Tap Start a new board, or Back to board.", note: "Every square done. Share is off in the tutorial.")

    /// Lesson 3 step 16's line after a tap that leaves squares open (16b): "Two
    /// left." and which line(s) the tap closed, which ring gold with no moment.
    /// - Parameters:
    ///   - remaining: Squares still open after the tap.
    ///   - newLines: The lines the tap closed, named ("the middle column").
    ///   - lineCount: Every line complete now, the Bingo's included.
    static func completeBoardFinaleStep(remaining: Int, newLines: [String], lineCount: Int) -> TutorialStep {
        let count = remaining == 1 ? "One" : (remaining == 2 ? "Two" : "\(remaining)")
        let note: String
        switch newLines.count {
        case 0:
            note = "No new line this time. Lines ring gold as they close; the moment only plays once per board here."
        case 1:
            let ordinals = ["second", "third", "fourth", "fifth", "sixth", "seventh", "eighth"]
            let ordinal = ordinals[min(max(lineCount - 2, 0), ordinals.count - 1)]
            note = "That made a \(ordinal) line, \(newLines[0]). It rings gold; the moment only plays once per board here."
        default:
            let words = ["two", "three", "four", "five", "six", "seven"]
            let many = newLines.count - 2 < words.count ? words[newLines.count - 2] : "\(newLines.count)"
            let joined = newLines.dropLast().joined(separator: ", ") + " and " + newLines[newLines.count - 1]
            note = "That made \(many) more lines, \(joined). They ring gold; the moment only plays once per board here."
        }
        return .action("\(count) left.", note: note)
    }
}

// MARK: - Copy helpers

extension TutorialProgress {
    /// The tutorial board's status line under the progress bar.
    func statusLine(activeLesson: TutorialLessonID?, activeStep: Int?) -> String {
        if isComplete { return "Greenlog" }
        if middleRowDone { return "Bingo · middle row" }
        if let lesson = activeLesson, let step = activeStep {
            let info = TutorialCatalog.info(for: lesson)
            return "\(info.title) · step \(step + 1) of \(info.steps.count)"
        }
        if doneCount == 0 { return "Tap a square to begin" }
        return "\(TutorialLessonID.total - doneCount) to go"
    }
}

/// The Profile "Getting started" row's caption. The row stays on Profile for
/// good (owner decision 2026-10-20: the walkthrough is always there to replay),
/// so after the free row it carries the board's own status line ("Bingo ·
/// middle row", then "Greenlog") instead of pointing at a locked Pro lesson;
/// before that, "Next: {the first free lesson not yet done}".
func gettingStartedCaption(progress: TutorialProgress) -> String {
    if progress.middleRowDone { return progress.statusLine(activeLesson: nil, activeStep: nil) }
    let next = TutorialLessonID.middleRow.first { progress.state(of: $0) != .done } ?? .createTask
    return "Next: \(TutorialCatalog.info(for: next).title)"
}
