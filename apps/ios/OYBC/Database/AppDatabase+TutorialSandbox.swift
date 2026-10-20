import Foundation
import GRDB
import SwiftUI

// MARK: - Tutorial sandbox
//
// Lessons 2 (Create a board) and 3 (Complete a board) of the Getting Started
// tutorial run the REAL screens against a throwaway in-memory `AppDatabase`
// seeded with supplied sample data (owner decision 2026-10-20): nothing is
// written to the user's own database, nothing syncs (`SyncService` is bound to
// `AppDatabase.shared` only), and the sandbox is simply dropped when the
// lesson finishes or is left. Lesson 1 (Create a task) is the one exception —
// it writes two real tasks to the user's library.

/// A seeded tutorial sandbox: the throwaway database plus the ids a lesson's
/// host screen needs to open it.
struct TutorialSandbox {
    /// The isolated in-memory database injected into the lesson's screens.
    let database: AppDatabase
    /// The sample board's id (lesson 3 only).
    let sampleBoardId: String?
}

extension AppDatabase {

    /// Creates a fresh, fully migrated in-memory database for a tutorial
    /// lesson. Production-named twin of the DEBUG-only `makeTestInstance()`;
    /// both share one `Configuration` (foreign keys ON) so a sandbox behaves
    /// exactly like the real store.
    static func makeTutorialSandbox() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: databaseConfiguration())
        return try AppDatabase(dbQueue: queue)
    }

    /// Builds and seeds the sandbox for a lesson.
    ///
    /// - Parameters:
    ///   - lesson: `.createBoard` (three supplied pools) or `.completeBoard`
    ///     (the half-played 3×3 "Sample week"). Any other lesson gets just
    ///     the user row.
    ///   - user: The signed-in user; the sandbox gets a copy of the row so
    ///     userId-scoped queries and the wizard's preferences resolve.
    ///   - resumeStep: The saved step being resumed (lesson 3 reseeds the board to
    ///     the state that step implies: Stretch done past its tap step, Read at
    ///     22/20 past the chip step, Tidy desk done past the hold step — see
    ///     `TutorialCatalog.CompleteStep`).
    ///   - now: The seeding instant (injectable for tests).
    static func seedTutorialSandbox(
        lesson: TutorialLessonID,
        user: User,
        resumeStep: Int = 0,
        now: Date = Date()
    ) throws -> TutorialSandbox {
        let db = try makeTutorialSandbox()
        try db.saveUser(user)
        switch lesson {
        case .createBoard:
            try db.seedTutorialPools(userId: user.id, now: now)
            return TutorialSandbox(database: db, sampleBoardId: nil)
        case .completeBoard:
            let boardId = try db.seedTutorialSampleWeek(
                userId: user.id,
                weekStartDay: user.decodedPreferences.weekStartDay.rawValue,
                resumeStep: resumeStep,
                now: now
            )
            return TutorialSandbox(database: db, sampleBoardId: boardId)
        default:
            return TutorialSandbox(database: db, sampleBoardId: nil)
        }
    }

    // MARK: - Lesson 2 — pools

    /// Supplied pool contents for lesson 2: Fitness 9, Reading 8, Home 8.
    /// Every pool fills a 3×3 (eight squares) on its own, and still does with
    /// one task left off plus the one the lesson adds by hand — the lesson
    /// pulls exactly one pool, so none may fall short. (The handoff's
    /// Reading 6 could not; two titles were added.)
    static let tutorialPoolSpecs: [(name: String, titles: [String])] = [
        ("Fitness", [
            "Run 5k", "Stretch 10 min", "Walk 10k steps", "Yoga", "Push-ups",
            "Bike to work", "Plank 2 min", "Lift weights", "Swim laps",
        ]),
        ("Reading", [
            "Read 20 pages", "Finish a chapter", "Read the news", "Read to the kids",
            "Visit the library", "Review notes", "Read a poem", "Browse a bookshop",
        ]),
        ("Home", [
            "Tidy desk", "Water plants", "Do the dishes", "Take out the trash",
            "Wipe counters", "Laundry", "Vacuum", "Plan meals",
        ]),
    ]

    /// Inserts the supplied pools and their (unplaced) Normal tasks.
    private func seedTutorialPools(userId: String, now: Date) throws {
        let ts = Self.tutorialTimestamp(now)
        try write { db in
            for spec in Self.tutorialPoolSpecs {
                var ids: [String] = []
                for title in spec.titles {
                    let task = Self.tutorialTask(id: Self.generateUUID(), userId: userId, title: title, now: ts)
                    try task.save(db)
                    ids.append(task.id)
                }
                let pool = Pool(
                    id: Self.generateUUID(), userId: userId, name: spec.name, taskIds: ids,
                    createdAt: ts, updatedAt: ts, version: 1, isDeleted: false
                )
                try pool.save(db)
            }
        }
    }

    // MARK: - Lesson 3 — Sample week

    /// The Sample week grid, row-major, with what is done at the start.
    ///
    /// Deviation from the handoff's literal grid (Stretch · Read · Call mom ✓ /
    /// Water plants ✓ · Walk ✓ · Tidy desk / Journal · Cook dinner ✓ · No sugar),
    /// owner decision 2026-10-20: the Bingo at step 9 must be ONE line. With
    /// four squares pre-done, seven of nine are done once Tidy desk lands, and
    /// two undone cells can block at most six of the eight lines, so two lines
    /// always close together; the literal grid also closes the top row at step
    /// 6. So Call mom starts undone (three pre-done, not four) and swaps places
    /// with Read 20 pages. Everything else is the handoff's: Tidy desk closes
    /// the middle row (Water plants · Walk · Tidy desk) and nothing else, and
    /// the finale is three squares (Call mom · Journal · No sugar).
    static let tutorialSampleWeekGrid: [TutorialSampleSquare] = [
        .init(title: "Stretch", kind: .normal, done: false),
        .init(title: "Call mom", kind: .normal, done: false),
        .init(title: "Read 20 pages", kind: .counting(action: "Read", unit: "pages", goal: 20, current: 12), done: false),
        .init(title: "Water plants", kind: .normal, done: true),
        .init(title: "Walk 10k steps", kind: .counting(action: "Walk", unit: "k steps", goal: 10, current: 10), done: true),
        .init(title: "Tidy desk", kind: .normal, done: false),
        .init(title: "Journal", kind: .normal, done: false),
        .init(title: "Cook dinner", kind: .normal, done: true),
        .init(title: "No sugar", kind: .normal, done: false),
    ]

    /// Library tasks the Edit swap picker can offer in place of "Journal".
    static let tutorialSpareTitles = ["Meditate 10 min", "Drink water", "Go for a walk"]

    /// Seeds the sample board, its nine tasks, the in-window events that make
    /// three squares done, a few spare library tasks, and re-derives the
    /// board's denormalized stats. Returns the board id.
    private func seedTutorialSampleWeek(userId: String, weekStartDay: String, resumeStep: Int, now: Date) throws -> String {
        let ts = Self.tutorialTimestamp(now)
        let window = computeWeekBoundaries(now, weekStartDay: weekStartDay)
        let boardId = Self.generateUUID()
        let grid = Self.tutorialSampleWeekGrid
        try write { db in
            let boardJSON: [String: Any] = [
                "id": boardId, "userId": userId, "name": "Sample week",
                "status": BoardStatus.active.rawValue, "boardSize": 3,
                "timeframe": Timeframe.weekly.rawValue,
                "startDate": wizardLocalISOString(window.start),
                "endDate": wizardLocalISOString(window.end),
                "centerSquareType": CenterSquareType.none.rawValue,
                "isRandomized": false, "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
                "createdAt": ts, "updatedAt": ts, "activatedAt": ts, "version": 1, "isDeleted": false,
            ]
            let board = try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: boardJSON))
            try board.save(db)
            for (index, square) in grid.enumerated() {
                let taskId = Self.generateUUID()
                // What a resumed lesson has already done (a saved step is the
                // index of the step to light next, so "past" a step is `>`):
                // Stretch, Read to 22/20, Tidy desk.
                let resumedDone = (square.title == "Stretch" && resumeStep > TutorialCatalog.CompleteStep.tapStretch)
                    || (square.title == "Tidy desk" && resumeStep > TutorialCatalog.CompleteStep.holdTidy)
                let resumedRead = square.title == "Read 20 pages" && resumeStep > TutorialCatalog.CompleteStep.logChip
                var task = Self.tutorialTask(id: taskId, userId: userId, title: square.title, now: ts)
                if case .counting(let action, let unit, let goal, let current) = square.kind {
                    task.type = .counting
                    task.action = action
                    task.unit = unit
                    task.maxCount = CountValue(goal)
                    task.currentCount = CountValue(resumedRead ? current + 10 : current)
                    task.isCompleted = square.done || resumedRead
                } else {
                    task.isCompleted = square.done || resumedDone
                }
                try task.save(db)
                let placement = BoardTask(
                    id: Self.generateUUID(), boardId: boardId, taskId: taskId,
                    row: index / 3, col: index % 3, isCenter: false,
                    createdAt: ts, updatedAt: ts, version: 1
                )
                try placement.save(db)
                // The in-window occurrences the resolver reads as "done so far".
                if resumedRead {
                    try Self.tutorialEvent(userId: userId, taskId: taskId, kind: .increment, delta: 10, now: ts).save(db)
                }
                switch square.kind {
                case .normal where square.done || resumedDone:
                    try Self.tutorialEvent(userId: userId, taskId: taskId, kind: .completion, delta: nil, now: ts).save(db)
                case .counting(_, _, _, let current) where current > 0:
                    try Self.tutorialEvent(userId: userId, taskId: taskId, kind: .increment, delta: CountValue(current), now: ts).save(db)
                default:
                    break
                }
            }
            for title in Self.tutorialSpareTitles {
                try Self.tutorialTask(id: Self.generateUUID(), userId: userId, title: title, now: ts).save(db)
            }
        }
        _ = try reDeriveActiveBoards(userId: userId)
        return boardId
    }

    // MARK: - Builders

    /// ISO8601 (UTC) timestamp for `date`, matching `currentTimestamp()`.
    private static func tutorialTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// A plain Normal task row.
    private static func tutorialTask(id: String, userId: String, title: String, now: String) -> Task {
        Task(
            id: id, userId: userId, title: title, type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
    }

    /// A synced-shape event row at `now`.
    private static func tutorialEvent(
        userId: String, taskId: String, kind: TaskEventKind, delta: CountValue?, now: String
    ) -> TaskEvent {
        TaskEvent(
            id: generateUUID(), userId: userId, taskId: taskId, kind: kind, delta: delta,
            occurredAt: now, boardId: nil, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }
}

/// One square of the Sample week seed.
struct TutorialSampleSquare {
    enum Kind {
        case normal
        case counting(action: String, unit: String, goal: Int, current: Int)
    }
    let title: String
    let kind: Kind
    /// Done at the start of the lesson (a completion event, or the goal reached).
    let done: Bool
}

// MARK: - Injected database (environment)

private struct AppDatabaseKey: EnvironmentKey {
    static var defaultValue: AppDatabase { .shared }
}

extension EnvironmentValues {
    /// The database the hosting screen reads and writes — `AppDatabase.shared`
    /// in the app, the throwaway sandbox inside a tutorial lesson. Leaf views
    /// that build their view-models as `@State` (before an init parameter could
    /// reach them) read this instead of reaching for the singleton.
    var appDatabase: AppDatabase {
        get { self[AppDatabaseKey.self] }
        set { self[AppDatabaseKey.self] = newValue }
    }
}
