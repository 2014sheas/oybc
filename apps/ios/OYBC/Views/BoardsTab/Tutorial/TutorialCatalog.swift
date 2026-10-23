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
    case sizeCard3
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
/// with no ring — a field the person already filled stays editable).
struct TutorialSpot: Hashable {
    let id: TutorialControlID
    var ringed: Bool = true
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

/// One walkthrough step: its one-line coach copy and how it ends.
struct TutorialStep: Equatable {
    /// How the step ends.
    enum Advance: Equatable {
        /// The wired control's event (the lesson state decides which).
        case action
        /// The coach mark's Next button (read-only step).
        case next
    }

    let text: String
    let advance: Advance
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

    // MARK: Scripts (one line per step)

    /// Lesson 1 · Create a task (7 steps) — the Tasks facsimile and the New task
    /// sheet facsimile; the two adds write real tasks.
    static let createTaskSteps: [TutorialStep] = [
        TutorialStep(text: "Tap + to add a task.", advance: .action),
        TutorialStep(text: "Type a task, then tap Add.", advance: .action),
        TutorialStep(text: "Tap to make a Counting task.", advance: .action),
        TutorialStep(text: "Start with the action, like Read.", advance: .action),
        TutorialStep(text: "Now the goal, a number.", advance: .action),
        TutorialStep(text: "Last, the unit. The title fills itself in.", advance: .action),
        TutorialStep(text: "Tap Add to library.", advance: .action),
    ]

    /// Lesson 2 · Create a board (9 steps) — the Create hub, the wizard's three
    /// steps and the source sheet, all facsimiles over the Fitness fixture.
    static let createBoardSteps: [TutorialStep] = [
        TutorialStep(text: "Tap to start a board.", advance: .action),
        TutorialStep(text: "Tap Weekly.", advance: .action),
        TutorialStep(text: "Tap 3×3, then Next.", advance: .action),
        TutorialStep(text: "Fill the board from a pool.", advance: .action),
        TutorialStep(text: "Tap Fitness, then Done.", advance: .action),
        TutorialStep(text: "Tap Fitness to see what it deals.", advance: .action),
        TutorialStep(text: "Tap ✕ on Bike to work to leave it out.", advance: .action),
        TutorialStep(text: "One short. Type a task of your own, then tap Add.", advance: .action),
        TutorialStep(text: "Activate it.", advance: .action),
    ]

    /// Lesson 2 step 8's second line, once the hand-added task restores 8/8.
    static let createBoardNextText = "Eight of eight. Tap Next."

    /// Lesson 3 · Complete a board (12 steps) — the Sample week facsimile with
    /// its Edit panel, replace sheet, square sheet and hold menu; the shipped
    /// moments play the Bingo and the Greenlog.
    static let completeBoardSteps: [TutorialStep] = [
        TutorialStep(text: "Tap Edit to change a square.", advance: .action),
        TutorialStep(text: "Tap Journal to swap it.", advance: .action),
        TutorialStep(text: "Pick Meditate 5 min.", advance: .action),
        TutorialStep(text: "Tap Save changes.", advance: .action),
        TutorialStep(text: "Tap Stretch to complete it.", advance: .action),
        TutorialStep(text: "Tapped by mistake? Undo lives here for a moment.", advance: .next),
        TutorialStep(text: "Tap Read 20 pages to log.", advance: .action),
        TutorialStep(text: "Tap +5 twice. Past the goal still counts.", advance: .action),
        TutorialStep(text: "22 of 20 counts. Undo lives here too.", advance: .next),
        TutorialStep(text: "Press and hold Tidy desk.", advance: .action),
        TutorialStep(text: "Tap Mark done.", advance: .action),
        TutorialStep(text: "Three left. Tap them all.", advance: .action),
    ]
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
