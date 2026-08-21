import Foundation

/// Navigation marker for pushing the tutorial board onto the Boards stack.
struct TutorialRoute: Hashable {}

/// Navigation routes for tutorial deep-links into Profile sub-pages.
///
/// P7 (Task Pools + Recurring Boards Rework): the former `.recurringTemplates`
/// and `.defaultPools` cases collapsed into one `.boardSettings` case —
/// both pages retired in favor of the single `BoardSettingsView`. Lower
/// risk than merging the two tutorial LESSONS that used to target them
/// (see `tutorialLessons` below): the 3×3 tutorial grid has exactly 8
/// fixed positions, and collapsing lessons would leave a hole to fill.
enum ProfileRoute: Hashable {
    case boardSettings
    /// Streaks & history page (handoff §5e).
    case streaks
}

/// Where a tutorial lesson's "Try it" button deep-links. Routed by
/// `MainTabView` (see its `handleTutorialTry`).
enum TutorialDeepLink {
    case createBoard     // → Create wizard
    case addTasks        // → Tasks tab / library
    case openABoard      // → newest board, else Create
    case boardSettings   // → Profile › Board settings (P7 — was recurringTemplates/defaultPools)
    case settings        // → Profile tab
    case shareGreenlog   // → sample GREENLOG preview overlay
}

/// One square on the Getting Started tutorial board. Port of `TUT_LESSONS`
/// from the design prototype (`proto/tutorial.jsx`).
struct TutorialLesson: Identifiable {
    let id: String
    /// Grid position 0–8 (index 4 is the FREE center, never a lesson).
    let pos: Int
    /// SF Symbol for the cell's icon tile.
    let systemImage: String
    /// Short category tag shown on the cell-less lesson sheet.
    let tag: String
    let title: String
    let blurb: String
    /// Three-step "how to" shown in the lesson sheet.
    let steps: [String]
    /// "Try it" button label.
    let cta: String
    let target: TutorialDeepLink
}

/// The eight lessons, in `pos` order (FREE center at index 4 is the gap).
let tutorialLessons: [TutorialLesson] = [
    TutorialLesson(
        id: "create", pos: 0, systemImage: "plus.circle", tag: "Basics",
        title: "Create a board",
        blurb: "Every goal starts as a bingo board. Pick a size and a timeframe, then fill it with tasks.",
        steps: ["Tap + on your boards", "Choose a size & timeframe", "Name it and start playing"],
        cta: "Try creating a board", target: .createBoard
    ),
    TutorialLesson(
        id: "tasks", pos: 1, systemImage: "list.bullet", tag: "Basics",
        title: "Add tasks",
        blurb: "Squares are your habits and goals. Add a simple check, a counter, or a multi-step task — or reuse one from your library.",
        steps: ["Open the Tasks step", "Type a task or reuse one", "Pick its type & goal"],
        cta: "Open the task library", target: .addTasks
    ),
    TutorialLesson(
        id: "complete", pos: 2, systemImage: "checkmark", tag: "Playing",
        title: "Complete a square",
        blurb: "Tap a square when you've done the thing. Counters tick up; compound tasks track each sub-step.",
        steps: ["Open any board", "Tap a square to mark it done", "Watch your progress climb"],
        cta: "Open a board", target: .openABoard
    ),
    TutorialLesson(
        id: "bingo", pos: 3, systemImage: "star", tag: "Playing",
        title: "Score a bingo",
        blurb: "Complete a full row, column, or diagonal to lock in a bingo. Lines glow gold — stack them for streaks.",
        steps: ["Fill five squares in a line", "The whole line locks gold", "Each line is a bingo"],
        cta: "See a near-bingo", target: .openABoard
    ),
    // index 4 = FREE center
    TutorialLesson(
        id: "recurring", pos: 5, systemImage: "repeat", tag: "Automate",
        title: "Repeating boards",
        blurb: "A repeating board prints a fresh card each cycle from a pool you pick — set it once and a new board is waiting every week.",
        steps: ["Create a board → set Repeats", "You → Board settings", "Pause, resume, or edit its mix"],
        cta: "Open Board settings", target: .boardSettings
    ),
    TutorialLesson(
        id: "pools", pos: 6, systemImage: "square.grid.3x3", tag: "Automate",
        title: "Core boards & pools",
        blurb: "Board settings holds your core boards' defaults — curate a pool or a few tasks and every renewed board deals from it.",
        steps: ["You → Board settings", "Tap a timeframe's defaults", "Attach a pool or add tasks"],
        cta: "Set up your defaults", target: .boardSettings
    ),
    TutorialLesson(
        id: "settings", pos: 7, systemImage: "gearshape", tag: "Settings",
        title: "Make it yours",
        blurb: "Dark mode, celebration intensity, board defaults — tune OYBC until it feels like yours.",
        steps: ["Open the You tab", "Try Appearance → Dark", "Set your board preferences"],
        cta: "Open settings", target: .settings
    ),
    TutorialLesson(
        id: "share", pos: 8, systemImage: "square.and.arrow.up", tag: "Celebrate",
        title: "Share a GREENLOG",
        blurb: "Clear a whole board for a GREENLOG — the page goes loud — then share the poster with friends.",
        steps: ["Fill every square", "Hit your GREENLOG", "Share the poster card"],
        cta: "Preview a GREENLOG", target: .shareGreenlog
    ),
]

/// Lesson lookup by grid position (nil at the FREE center, index 4).
let tutorialLessonsByPos: [Int: TutorialLesson] = {
    var map: [Int: TutorialLesson] = [:]
    for lesson in tutorialLessons { map[lesson.pos] = lesson }
    return map
}()

/// The 1-based "Move N of 8" index for a lesson, in `tutorialLessons` order.
func tutorialMoveNumber(for lesson: TutorialLesson) -> Int {
    (tutorialLessons.firstIndex(where: { $0.id == lesson.id }) ?? 0) + 1
}
