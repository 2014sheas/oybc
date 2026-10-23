import Foundation
import SwiftUI

// MARK: - Session

/// A running lesson: where the person is in the script and the fixture state
/// its facsimiles show.
struct TutorialSession: Equatable {
    /// What the stage is showing on top of the lesson.
    enum Phase: Equatable {
        /// The walkthrough is live.
        case running
        /// The "Leave this lesson?" sheet is up.
        case confirmingLeave
        /// The last step finished; the lesson-complete card shows.
        case complete
    }

    let lesson: TutorialLessonID
    /// 0-based index into the lesson's steps.
    var step: Int
    /// The lesson reopened mid-way — the first coach mark carries the RESUMED tag.
    var resumed: Bool
    var phase: Phase = .running
    var state: TutorialStageState
    /// Where the stage lands once the complete phase ends (set by the Greenlog's
    /// "Start a new board" and the complete card's plain link).
    var exit: TutorialExit = .board

    var info: TutorialLessonInfo { TutorialCatalog.info(for: lesson) }
    var steps: [TutorialStep] { info.steps }
    var currentStep: TutorialStep? { steps.indices.contains(step) ? steps[step] : nil }

    /// The controls lit right now.
    var spots: [TutorialSpot] { phase == .running ? state.spots(step: step) : [] }

    /// The coach mark's line.
    var text: String { state.textOverride(step: step) ?? currentStep?.text ?? "" }

    /// Whether the coach mark shows Next (read-only step).
    var showsNext: Bool { currentStep?.advance == .next }
}

// MARK: - Coordinator

/// Runs the Getting Started tutorial: owns the synced progress and the active
/// lesson's step machine. The facsimiles report events through `perform(_:)`;
/// the lesson state decides what they mean. Lesson 1's two adds are the only
/// real writes, through the injected database.
@MainActor
final class TutorialCoordinator: ObservableObject {

    /// The synced progress (mirrors `UserPreferences.tutorialProgress`).
    @Published private(set) var progress: TutorialProgress
    /// The running lesson, if any.
    @Published private(set) var session: TutorialSession?
    /// The lesson that just finished (and where it exits), until the tutorial
    /// board plays its pop.
    @Published private(set) var justCompleted: (lesson: TutorialLessonID, exit: TutorialExit)?

    /// The lesson is closing: the stage cover is animating out. The session
    /// stays alive until `stageDidDismiss()` so nothing flashes mid-animation.
    @Published private(set) var isClosing = false

    private let database: AppDatabase
    private let userId: String?
    private let persists: Bool

    /// - Parameters:
    ///   - userId: The signed-in user; nil makes a preview coordinator.
    ///   - database: The user's real database (progress and lesson 1's tasks are written here).
    ///   - progress: Initial progress (from the user's preferences).
    init(userId: String?, database: AppDatabase = .shared, progress: TutorialProgress = .empty) {
        self.userId = userId
        self.database = database
        self.progress = progress
        self.persists = userId != nil
    }

    /// A coordinator that never touches a database — previews and snapshots.
    static func preview(progress: TutorialProgress = .empty, session: TutorialSession? = nil) -> TutorialCoordinator {
        let coordinator = TutorialCoordinator(userId: nil, progress: progress)
        coordinator.session = session
        return coordinator
    }

    // MARK: Progress

    /// Pulls in a progress value that changed elsewhere (a sync pull).
    func refresh(from remote: TutorialProgress) {
        if remote != progress { progress = remote }
    }

    /// Publishes `updated` immediately and writes it into the user's synced
    /// preferences (`AppDatabase.updateUserPreferences`: version bump + one
    /// `users` sync item). A preview coordinator (no user) only publishes.
    /// - Parameter updated: The full progress value to store.
    private func persist(_ updated: TutorialProgress) {
        progress = updated
        guard persists, let userId else { return }
        do {
            try database.updateUserPreferences(userId: userId) { current in
                var next = current
                next.tutorialProgress = updated
                return next
            }
        } catch {
            dlog("⚠️ TutorialCoordinator: persisting progress failed: \(error)")
        }
    }

    /// Saves `step` as the lesson's place when it is further than what is saved.
    /// Never lowers a saved step, never touches a finished lesson and writes
    /// nothing when nothing changed (no version bump).
    private func recordStep(_ lesson: TutorialLessonID, step: Int) {
        guard step > 0 else { return }
        let saved: Int
        switch progress.state(of: lesson) {
        case .done: return
        case .inProgress(let s): saved = s
        default: saved = 0
        }
        guard step > saved else { return }
        var next = progress
        next.set(lesson, .inProgress(step: step))
        persist(next)
    }

    /// Hides the Boards-tab card (allowed once the middle row is done).
    func dismissCard() {
        guard progress.canDismissCard, !progress.cardDismissed else { return }
        var next = progress
        next.cardDismissed = true
        persist(next)
    }

    /// Clears all progress and un-dismisses the card (the DEBUG reset).
    func reset() {
        tearDown()
        justCompleted = nil
        for lesson in TutorialLessonID.middleRow { TutorialTypedCache.clear(lesson) }
        persist(.empty)
    }

    // MARK: Lesson lifecycle

    /// Opens a lesson at its saved step (or step 1 for a fresh / replayed one),
    /// rebuilding the fixture the steps before it imply.
    /// - Returns: false for a Pro square or while another lesson runs.
    @discardableResult
    func start(_ lesson: TutorialLessonID) -> Bool {
        guard lesson.isFree, session == nil else { return false }
        let count = TutorialCatalog.info(for: lesson).steps.count
        var saved = 0
        if case .inProgress(let savedStep) = progress.state(of: lesson) {
            saved = min(savedStep, max(count - 1, 0))
        }
        if saved == 0 { TutorialTypedCache.clear(lesson) }
        guard let state = TutorialStageState.implied(lesson: lesson, step: saved, typed: TutorialTypedCache.load(lesson)) else { return false }
        isClosing = false
        session = TutorialSession(lesson: lesson, step: saved, resumed: saved > 0, state: state)
        return true
    }

    /// A facsimile's event: the lesson state applies it and the step moves (or
    /// not). Lesson 1's writes happen here, before the step moves.
    func perform(_ event: TutorialEvent) {
        guard var current = session, current.phase == .running, !isClosing else { return }
        let outcome = current.state.apply(event, step: current.step)
        switch outcome {
        case .ignored:
            return
        case .stayed:
            session = current
        case .advanced:
            current.resumed = false
            current.step += 1
            session = current
            recordStep(current.lesson, step: current.step)
        case .completed(let exit):
            complete(current, exit: exit)
        case .writes(let write):
            guard write.perform(database: database, userId: userId) else { return }
            // Lesson 1's last add completes the lesson; the first moves on.
            if current.step + 1 >= current.steps.count {
                complete(current, exit: nil)
            } else {
                current.resumed = false
                current.step += 1
                session = current
                recordStep(current.lesson, step: current.step)
            }
        }
        if let session { TutorialTypedCache.save(session.lesson, session.state.typed) }
    }

    /// The coach mark's Next (read-only steps).
    func next() { perform(.nextTapped) }

    /// Records the lesson done and shows the complete card — or, with an exit,
    /// closes the stage straight to that tab (the Greenlog's "Start a new board").
    private func complete(_ current: TutorialSession, exit: TutorialExit?) {
        var ending = current
        ending.phase = .complete
        ending.exit = exit ?? .board
        session = ending
        var next = progress
        next.set(current.lesson, .done)
        if next != progress { persist(next) }
        TutorialTypedCache.clear(current.lesson)
        if exit != nil { finishCompletedLesson(exit: exit ?? .board) }
    }

    // MARK: Leaving

    /// The bar's ✕: asks before leaving.
    func requestLeave() {
        guard var current = session, current.phase == .running else { return }
        current.phase = .confirmingLeave
        session = current
    }

    /// "Keep going" on the leave sheet.
    func keepGoing() {
        guard var current = session, current.phase == .confirmingLeave else { return }
        current.phase = .running
        session = current
    }

    /// "Leave": saves the step (never lowering it, never touching a finished
    /// lesson), keeps what was typed for the resume, and closes the stage.
    func leave() {
        guard let current = session else { return }
        recordStep(current.lesson, step: current.step)
        TutorialTypedCache.save(current.lesson, current.state.typed)
        var ending = current
        ending.phase = .running
        session = ending
        isClosing = true
    }

    /// The complete card's buttons (and a moment's exit): closes the stage and
    /// tells the tutorial board where to land.
    func finishCompletedLesson(exit: TutorialExit = .board) {
        guard let current = session, current.phase == .complete else { return }
        justCompleted = (current.lesson, exit)
        isClosing = true
    }

    /// The tutorial board played the square pop (and any Bingo toast).
    func consumeJustCompleted() {
        justCompleted = nil
    }

    /// The stage cover finished dismissing (any way it was dismissed). A lesson
    /// still running is left first so its place is saved, then the session is
    /// torn down.
    func stageDidDismiss() {
        if session != nil, !isClosing { leave() }
        tearDown()
    }

    private func tearDown() {
        session = nil
        isClosing = false
    }
}

// MARK: - Lesson 1 writes

extension TutorialWrite {
    /// Writes the task to the real library, the way the Tasks tab's quick add
    /// and special-type panel do (`createTaskAndEnqueue`: one row + one sync
    /// item). A preview coordinator (no user) writes nothing and reports success.
    /// - Returns: false when the write failed (the lesson stays on its step).
    @MainActor
    func perform(database: AppDatabase, userId: String?) -> Bool {
        guard let userId else { return true }
        let now = AppDatabase.currentTimestamp()
        let task: Task
        switch self {
        case .simple(let title):
            task = Task(
                id: AppDatabase.generateUUID(), userId: userId, title: title, type: .normal,
                totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        case .counting(let verb, let goal, let unit):
            let title = TaskTitle.generateCounterTaskTitle(action: verb, maxCount: CountValue(goal), unit: unit, countKind: .discrete)
            task = Task(
                id: AppDatabase.generateUUID(), userId: userId, title: title, type: .counting,
                action: verb, unit: unit, maxCount: CountValue(goal),
                totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        }
        do {
            try database.createTaskAndEnqueue(task, now: now)
            return true
        } catch {
            dlog("⚠️ TutorialCoordinator: lesson 1 write failed: \(error)")
            return false
        }
    }
}

// MARK: - Typed cache

/// What the person typed in a lesson, kept device-locally so a resume rebuilds
/// the facsimile with their own words ("Resume restores … task typed"). Not
/// progress — that syncs in `TutorialProgress`.
enum TutorialTypedCache {
    private static func key(_ lesson: TutorialLessonID) -> String { "oybc.tutorial.typed.\(lesson.rawValue)" }

    static func load(_ lesson: TutorialLessonID) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key(lesson)) as? [String: String] ?? [:]
    }

    static func save(_ lesson: TutorialLessonID, _ typed: [String: String]) {
        if typed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(lesson))
        } else {
            UserDefaults.standard.set(typed, forKey: key(lesson))
        }
    }

    static func clear(_ lesson: TutorialLessonID) {
        UserDefaults.standard.removeObject(forKey: key(lesson))
    }
}
