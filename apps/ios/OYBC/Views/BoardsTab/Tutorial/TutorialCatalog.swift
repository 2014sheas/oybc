import SwiftUI

// MARK: - Anchors

/// A control a walkthrough step can light. Real screens tag the control with
/// `.tutorialAnchor(_:)`; the coach layer resolves the frame from the anchor
/// preference. Tagging is inert when no lesson is running.
enum TutorialAnchorID: Hashable {
    // Lesson 1 — Create a task
    case tasksPlus
    case quickAddCard
    case specialTypeButton
    case countingVerb
    case countingKind
    case countingGoal
    case addToLibrary
    // Lesson 2 — Create a board
    case startOneOffCTA
    case boardSizeCards
    case timeframePicker
    case wizardNext
    case addFromPoolRow
    case sourcePoolRows
    case sourcesDone
    /// The pulled pool's row on the Tasks step (tap expands it).
    case sourceRow
    /// The expanded pool's member rows (each with its ✕).
    case memberRows
    /// The Tasks step's quick-add card.
    case wizardQuickAdd
    /// Preview's Shuffle button.
    case shuffleButton
    /// Preview's Preview ⇄ Rearrange toggle.
    case rearrangeToggle
    /// Preview's board grid.
    case previewGrid
    case activateBoard
    // Lesson 3 — Complete a board
    case editButton
    case editSave
    /// A play-board square by row-major slot.
    case square(Int)
    /// A square in the Board Edit grid by row-major slot.
    case editSquare(Int)
    case undoToast
    case logChips
    case undoStrip
}

// MARK: - Events

/// What a real control reports when the user uses it. Action steps advance only
/// when their event arrives (no simulated taps).
enum TutorialEvent: Equatable {
    // Lesson 1
    case tasksPlusTapped
    case normalTaskCreated
    case specialPanelOpened
    case countingFieldsFilled
    case countingTaskCreated
    // Lesson 2
    case oneOffBoardStarted
    case boardSizePicked
    case setupNext
    case sourcesSheetOpened
    /// The sources sheet closed (Done) with a pool pulled that fills the board.
    case poolsPicked
    /// The pulled pool's row was expanded on the Tasks step.
    case sourceRowExpanded
    /// A pool member was excluded (✕) for this board.
    case memberExcluded
    /// A task was added by hand on the Tasks step (quick-add or a library match).
    case manualTaskAdded
    case tasksStepNext
    /// Preview's Shuffle dealt the squares again.
    case previewShuffled
    /// A square was moved or swapped on Preview's grid.
    case previewRearranged
    case boardActivated
    // Lesson 3
    case editEntered
    /// A square's task was replaced through the Edit tap-menu.
    case squareSwapped
    case editSaved
    case simpleSquareDone
    case countingSheetOpened
    case countLogged
    case bingoMomentClosed
    case greenlogMomentClosed
    // Retreats — a lit sheet was dismissed before its step's action
    /// The sources sheet closed with no pool filling the board.
    case sourcesSheetClosedEmpty
    /// The square sheet closed (swipe-down or any hand-off).
    case squareSheetClosed
    /// The square sheet's Undo strip was used (the log is gone, so is the strip).
    case squareLogUndone
}

// MARK: - Steps

/// What the lit play-board squares accept during a lesson-3 step. Every other
/// gesture on a square is off, so each step has exactly one way through.
enum TutorialSquareInteraction: Equatable {
    /// No lesson running: squares behave as shipped.
    case free
    /// Squares are inert (the step is on a sheet, in Edit, or waiting for Next).
    case none
    /// Tap only (completes a Simple square / opens a Counting sheet); no hold menu.
    case tap
    /// Hold only, and the menu offers only "Mark done".
    case hold

    var allowsTap: Bool { self == .free || self == .tap }
    var allowsHold: Bool { self == .free || self == .hold }
}

/// One walkthrough step: the lit controls, the one-line instruction and how it
/// advances.
struct TutorialStep: Equatable {
    /// How the step ends.
    enum Advance: Equatable {
        /// The real control's event.
        case action(TutorialEvent)
        /// The coach mark's Next button (read-only step).
        case next
    }

    /// Lit controls; the first is the coach mark's target.
    let anchors: [TutorialAnchorID]
    let text: String
    let advance: Advance
    /// After an action step's event, the lesson pauses on this line (with
    /// Next) before lighting the next control, so nothing moves on its own.
    /// nil: the next step follows at once (it is read-only, or the lesson
    /// completes).
    var doneText: String? = nil
    /// The lit control lives in a presented sheet, so the screen behind it dims too.
    var onSheet: Bool = false
    /// Entering this step closes the square sheet (lesson 3, hold-menu step).
    var closesSquareSheet: Bool = false
    /// The lit control is the Undo toast: it stays up until Next (lesson 3).
    var holdsToast: Bool = false
    /// The finale lights EVERY still-incomplete square, not fixed anchors.
    var litsIncompleteSquares: Bool = false
    /// Place the coach mark above the lit controls (the default is below).
    var prefersAbove: Bool = false
    /// Copy that depends on what the user just did; `text` is the fallback.
    var dynamic: DynamicText? = nil
    /// The same, for `doneText`.
    var doneDynamic: DynamicText? = nil
    /// What the lit squares accept (lesson 3).
    var squareInteraction: TutorialSquareInteraction = .none

    /// A step line completed from what a real control reported.
    enum DynamicText: Equatable {
        /// Lesson 3: "{22 of 20}. The square is done; Undo stays here."
        case loggedSummary
        /// Lesson 2: "{Fitness} fills {eight} squares."
        case poolFills
        /// Lesson 3 finale: "{Two} left. Complete them for a Greenlog."
        case remainingSquares
    }
}

// MARK: - Lesson definitions

/// Static description of one tutorial square: its copy, glyph and (for the free
/// lessons) its walkthrough script.
struct TutorialLessonInfo: Identifiable {
    let id: TutorialLessonID
    let title: String
    /// SF Symbol for a free lesson's icon tile; nil for Pro placeholders.
    let glyph: String?
    /// The lesson-complete card's second line.
    let completeSubtitle: String
    let steps: [TutorialStep]

    var isFree: Bool { id.isFree }
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
                completeSubtitle: "Create a task · both tasks are in your library",
                steps: createTaskSteps
            )
        case .createBoard:
            return TutorialLessonInfo(
                id: id, title: "Create a board", glyph: "square.grid.3x3",
                completeSubtitle: "Create a board · sample board cleared",
                steps: createBoardSteps
            )
        case .completeBoard:
            return TutorialLessonInfo(
                id: id, title: "Complete a board", glyph: "checkmark",
                completeSubtitle: "Complete a board · a Bingo and a Greenlog",
                steps: completeBoardSteps
            )
        }
    }

    /// Where a saved lesson reopens. The sandbox lesson 3 can reseed its board to
    /// the state a step implies, so it resumes at (or just after) the saved step,
    /// skipping steps whose control is no longer on screen (the Edit panel, the
    /// toast, the closed sheet). Lessons 1 and 2 cannot rebuild their mid-flow
    /// screens (an open sheet, the wizard's state), so they reopen at step 1
    /// (the RESUMED tag still shows).
    static func resumeStep(lesson: TutorialLessonID, saved: Int) -> Int {
        guard lesson == .completeBoard else { return 0 }
        switch saved {
        case CompleteStep.swapSquare, CompleteStep.saveEdit: return CompleteStep.enterEdit   // the Edit panel is not open
        case CompleteStep.undoToast: return CompleteStep.openRead                           // the Undo toast is gone
        case CompleteStep.logChip: return CompleteStep.openRead                             // the square sheet is closed: open Read again
        case CompleteStep.undoStrip: return CompleteStep.holdTidy                           // the sheet is closed, Read is already at 22/20
        default: return saved
        }
    }

    /// A Pro placeholder: no script, no glyph.
    private static func pro(_ id: TutorialLessonID, _ title: String) -> TutorialLessonInfo {
        TutorialLessonInfo(id: id, title: title, glyph: nil, completeSubtitle: "", steps: [])
    }

    /// The nine titles in grid order (the tutorial Greenlog's squares).
    static var titles: [String] { lessons.map(\.title) }

    // MARK: Scripts (one line per step)

    /// Lesson 1 · Create a task — Tasks tab › New task sheet, real tasks. The
    /// sheet offers only what the lesson teaches: a Counting task, Discrete.
    static let createTaskSteps: [TutorialStep] = [
        TutorialStep(anchors: [.tasksPlus], text: "Tap + to add a task.", advance: .action(.tasksPlusTapped),
                     doneText: "The new task sheet is open."),
        TutorialStep(anchors: [.quickAddCard], text: "Type a task, then tap Add.", advance: .action(.normalTaskCreated),
                     doneText: "Added. It is in your library.", onSheet: true),
        TutorialStep(anchors: [.specialTypeButton], text: "Tap to make a Counting task.", advance: .action(.specialPanelOpened),
                     doneText: "Counting: a goal and a unit.", onSheet: true),
        TutorialStep(anchors: [.countingVerb, .countingKind, .countingGoal], text: "Action, then goal, then unit. The title fills itself in.", advance: .action(.countingFieldsFilled),
                     doneText: "The title filled itself in.", onSheet: true, prefersAbove: true),
        TutorialStep(anchors: [.addToLibrary], text: "Tap Add to library.", advance: .action(.countingTaskCreated), onSheet: true),
    ]

    /// Lesson 2 · Create a board — Create tab › board wizard on the sandbox:
    /// one pool, one task left off it, one task added by hand, then the
    /// Preview's Shuffle and Rearrange before Activate.
    static let createBoardSteps: [TutorialStep] = [
        TutorialStep(anchors: [.startOneOffCTA], text: "Tap to start a board.", advance: .action(.oneOffBoardStarted),
                     doneText: "Setup first: a size, then a timeframe."),
        TutorialStep(anchors: [.boardSizeCards], text: "Pick a size.", advance: .action(.boardSizePicked),
                     doneText: "3×3: eight squares to fill around a free centre."),
        TutorialStep(anchors: [.timeframePicker, .wizardNext], text: "Pick a timeframe, then tap Next.", advance: .action(.setupNext),
                     doneText: "Now the tasks."),
        TutorialStep(anchors: [.addFromPoolRow], text: "Fill the board from a pool.", advance: .action(.sourcesSheetOpened),
                     doneText: "Your pools, ready to pull from."),
        TutorialStep(anchors: [.sourcePoolRows, .sourcesDone], text: "Pick one pool, then tap Done.", advance: .action(.poolsPicked),
                     doneText: "Fitness fills eight squares.", onSheet: true, doneDynamic: .poolFills),
        TutorialStep(anchors: [.sourceRow], text: "Tap the pool to see its tasks.", advance: .action(.sourceRowExpanded),
                     doneText: "Every task the pool can deal."),
        TutorialStep(anchors: [.memberRows], text: "Tap ✕ to leave a task off this board.", advance: .action(.memberExcluded),
                     doneText: "Left off. The pool deals from the rest."),
        TutorialStep(anchors: [.wizardQuickAdd], text: "Add a task of your own.", advance: .action(.manualTaskAdded),
                     doneText: "Added, alongside the pool."),
        TutorialStep(anchors: [.wizardNext], text: "Tap Next to preview the board.", advance: .action(.tasksStepNext),
                     doneText: "The squares, as they will be dealt."),
        TutorialStep(anchors: [.shuffleButton], text: "Tap Shuffle to deal the squares again.", advance: .action(.previewShuffled),
                     doneText: "A new deal."),
        TutorialStep(anchors: [.rearrangeToggle, .previewGrid], text: "Tap Rearrange, then drag a square somewhere new.", advance: .action(.previewRearranged),
                     doneText: "Moved. Squares stay where you put them."),
        TutorialStep(anchors: [.activateBoard], text: "Activate it.", advance: .action(.boardActivated)),
    ]

    /// Row-major slots of the Sample week squares the script points at (see
    /// `AppDatabase.tutorialSampleWeekGrid`).
    enum SampleSlot {
        static let stretch = 0
        static let callMom = 1
        static let read = 2
        static let tidy = 5
        static let journal = 6
        static let noSugar = 8
    }

    /// Lesson 3 step indices (the retreats, the resume map and the sandbox
    /// reseed all name steps through these).
    enum CompleteStep {
        static let enterEdit = 0
        static let swapSquare = 1
        static let saveEdit = 2
        static let tapStretch = 3
        static let undoToast = 4
        static let openRead = 5
        static let logChip = 6
        static let undoStrip = 7
        static let holdTidy = 8
        static let finale = 9
    }

    /// Lesson 3 · Complete a board — the sandbox "Sample week". Every step
    /// names its square, and the squares accept only that step's gesture.
    static let completeBoardSteps: [TutorialStep] = [
        TutorialStep(anchors: [.editButton], text: "Tap Edit to change a square.", advance: .action(.editEntered),
                     doneText: "Edit is open."),
        TutorialStep(anchors: [.editSquare(SampleSlot.journal)], text: "Tap \(sampleTitle(SampleSlot.journal)), then Replace task.", advance: .action(.squareSwapped),
                     doneText: "\(sampleTitle(SampleSlot.journal)) is swapped out."),
        TutorialStep(anchors: [.editSave], text: "Save changes.", advance: .action(.editSaved),
                     doneText: "Saved."),
        TutorialStep(anchors: [.square(SampleSlot.stretch)], text: "Tap \(sampleTitle(SampleSlot.stretch)) to complete it.", advance: .action(.simpleSquareDone),
                     squareInteraction: .tap),
        TutorialStep(anchors: [.undoToast], text: "Tapped by mistake? Undo lives here for a moment.", advance: .next, holdsToast: true),
        TutorialStep(anchors: [.square(SampleSlot.read)], text: "Tap \(sampleTitle(SampleSlot.read)) to log.", advance: .action(.countingSheetOpened),
                     doneText: "\(sampleTitle(SampleSlot.read)) is open.", squareInteraction: .tap),
        TutorialStep(anchors: [.logChips], text: "Log with a chip. Past the goal still counts.", advance: .action(.countLogged), onSheet: true),
        TutorialStep(anchors: [.undoStrip], text: "22 of 20. The square is done; Undo stays here.", advance: .next, onSheet: true, dynamic: .loggedSummary),
        TutorialStep(anchors: [.square(SampleSlot.tidy)], text: "Hold \(sampleTitle(SampleSlot.tidy)), then tap Mark done.", advance: .action(.bingoMomentClosed),
                     doneText: "Bingo: the middle row is done.", closesSquareSheet: true, squareInteraction: .hold),
        TutorialStep(anchors: [.square(SampleSlot.callMom), .square(SampleSlot.journal), .square(SampleSlot.noSugar)], text: "Three left. Tap each to complete it.", advance: .action(.greenlogMomentClosed),
                     litsIncompleteSquares: true, dynamic: .remainingSquares, squareInteraction: .tap),
    ]

    // MARK: Retreats (a lit sheet closed early)

    /// Where a lesson goes when a presentation its step lit is dismissed before
    /// the step's action happened — a hand-off the scrim cannot stop. The
    /// lesson steps back to the control that reopens the sheet, or on a
    /// read-only sheet step, straight on to the step that would have closed
    /// it. Returns nil when the event means nothing at this step.
    static func retreat(lesson: TutorialLessonID, step: Int, event: TutorialEvent) -> Int? {
        switch (lesson, event) {
        case (.createBoard, .sourcesSheetClosedEmpty) where step == 4:
            return 3                                                // light "Add from a pool or board" again
        case (.completeBoard, .squareSheetClosed) where step == CompleteStep.logChip:
            return CompleteStep.openRead                            // light Read again
        case (.completeBoard, .squareSheetClosed) where step == CompleteStep.undoStrip:
            return CompleteStep.holdTidy                            // the sheet is already gone: hold Tidy desk
        case (.completeBoard, .squareLogUndone) where step == CompleteStep.undoStrip:
            return CompleteStep.logChip                             // the log was undone: log with a chip again
        default:
            return nil
        }
    }

    /// The title that starts in a Sample week slot (`.square(slot)` anchors
    /// name squares by their seeded slot; the board reports where each title
    /// sits now, since Edit lets the person drag squares around).
    static func sampleTitle(atSeededSlot slot: Int) -> String? {
        let grid = AppDatabase.tutorialSampleWeekGrid
        return grid.indices.contains(slot) ? grid[slot].title : nil
    }

    /// The seeded title for the step copy ("Tap Stretch to complete it.").
    private static func sampleTitle(_ slot: Int) -> String {
        sampleTitle(atSeededSlot: slot) ?? "the square"
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
