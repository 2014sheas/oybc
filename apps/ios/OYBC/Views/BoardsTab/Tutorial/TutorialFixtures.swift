import Foundation

// MARK: - Fixtures
//
// The lessons run over tutorial-owned facsimile screens fed by these static
// fixtures — plain in-memory models that never enter the board store, the
// counters, notifications or widgets. Lesson 1 is the one exception: its two
// adds write real tasks (through the coordinator's injected database).

/// One task of a fixture pool or board.
struct TutorialFixtureTask: Hashable {
    let title: String
    /// A Counting task's goal; nil for a Simple one.
    var goal: Int? = nil
    /// A Counting task's unit ("pages", "k steps").
    var unit: String = ""

    var isCounting: Bool { goal != nil }
}

/// The lesson 2 fixtures: the board the wizard "creates" and the pools the
/// source sheet lists.
enum TutorialCreateBoardFixture {
    static let boardName = "Sample board"
    static let handAddedDefault = "Drink water"
    static let excludedTitle = "Bike to work"

    /// Fitness: exactly the eight tasks a 3×3 with a free centre needs, so the
    /// person feels the count move (8/8 → 7/8 → 8/8).
    static let fitness: [TutorialFixtureTask] = [
        .init(title: "Run 5k"), .init(title: "Stretch 10 min"), .init(title: "Walk 10k steps", goal: 10, unit: "k steps"),
        .init(title: "Yoga"), .init(title: "Push-ups", goal: 50, unit: "push-ups"), .init(title: excludedTitle),
        .init(title: "Plank 2 min"), .init(title: "Lift weights"),
    ]

    /// The source sheet's rows: name + task count; only Fitness is live.
    static let pools: [(name: String, count: Int)] = [("Fitness", fitness.count), ("Reading", 6), ("Home", 8)]
    static let livePool = "Fitness"

    /// Squares the board needs around its free centre.
    static let required = 8

    /// The Preview grid (row-major, nil = the FREE centre): Fitness in order
    /// with the hand-added task in the excluded task's place.
    static func previewCells(handAdded: String) -> [TutorialFixtureTask?] {
        let final = fitness.map { $0.title == excludedTitle ? TutorialFixtureTask(title: handAdded) : $0 }
        return Array(final[0..<4]) + [nil] + Array(final[4...])
    }
}

/// One square of the Sample week.
struct TutorialSampleSquare: Hashable {
    let title: String
    var goal: Int? = nil
    var unit: String = ""
    /// A Counting square's count at the start.
    var count: Int = 0
    /// Done at the start of the lesson.
    var done: Bool = false

    var isCounting: Bool { goal != nil }
}

/// The lesson 3 fixture: a half-played weekly 3×3, centre None, laid out so no
/// line completes before the hold step (Stretch, then Read, then the middle row).
enum TutorialSampleWeek {
    static let boardName = "Sample week"
    static let kicker = "Weekly board"
    static let daysLeft = "4d"

    /// Row-major slots the script points at.
    enum Slot {
        static let stretch = 0
        static let journal = 1
        static let callMom = 2
        static let walk = 3
        static let read = 4
        static let tidy = 5
        static let noSugar = 6
        static let cookDinner = 7
        static let waterPlants = 8
    }

    static let grid: [TutorialSampleSquare] = [
        .init(title: "Stretch"), .init(title: "Journal"), .init(title: "Call mom", done: true),
        .init(title: "Walk 10k steps", goal: 10, unit: "k steps", count: 10, done: true),
        .init(title: "Read 20 pages", goal: 20, unit: "pages", count: 12), .init(title: "Tidy desk"),
        .init(title: "No sugar"), .init(title: "Cook dinner", done: true), .init(title: "Water plants"),
    ]

    /// What the swap puts in Journal's place.
    static let replacement = "Meditate 5 min"
    /// The replace sheet's library; only `replacement` is live.
    static let replaceLibrary = ["Meditate 5 min", "Floss", "Make the bed", "Read the news"]
    /// The square sheet's chip the lesson wires.
    static let chip = 5
    /// The chips the square sheet offers (+1 · +5 · +rest ✓ · Other…).
    static let chips = [1, 5]

    /// Slots done at the start.
    static var initiallyDone: Set<Int> { Set(grid.indices.filter { grid[$0].done }) }

    /// The eight lines of a 3×3, as row-major slots.
    static let lines: [[Int]] = [
        [0, 1, 2], [3, 4, 5], [6, 7, 8],
        [0, 3, 6], [1, 4, 7], [2, 5, 8],
        [0, 4, 8], [2, 4, 6],
    ]

    /// The lines complete in `done`.
    static func completeLines(_ done: Set<Int>) -> [[Int]] {
        lines.filter { $0.allSatisfy(done.contains) }
    }
}
