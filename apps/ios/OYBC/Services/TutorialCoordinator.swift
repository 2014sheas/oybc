import Foundation
import SwiftUI

// MARK: - Session

/// A running lesson: where the user is in the script and what the lesson owns.
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
    /// A Bingo / Greenlog moment is on screen — the coach layer steps aside.
    var momentOpen: Bool = false
    /// Lesson 3: what the last log produced ("22 of 20"), for the step copy.
    var logSummary: String?
    /// Lesson 3: whether that log finished the square.
    var logFinishedSquare: Bool = false
    /// Lesson 2: the picked pool's line ("Fitness fills eight squares").
    var poolSummary: String?
    /// The sandbox's sample board id (lesson 3).
    var sampleBoardId: String?

    /// The lesson's script.
    var steps: [TutorialStep] { TutorialCatalog.info(for: lesson).steps }

    /// The current step (nil once past the end).
    var currentStep: TutorialStep? { steps.indices.contains(step) ? steps[step] : nil }
}

/// The value-typed slice of coordinator state that real screens read from the
/// environment to react to (e.g. a sheet closing when the lesson completes).
struct TutorialSignals: Equatable {
    var active: Bool = false
    var step: Int = 0
    var phase: TutorialSession.Phase = .running
    /// The lesson runs on a throwaway sandbox database: everything the lesson
    /// does not teach is dimmed and inert.
    var sandboxed: Bool = false
    /// The current step wants the square sheet closed (lesson 3, hold-menu step).
    var closesSquareSheet: Bool = false
    /// The current step points at the Undo toast — keep it up until Next.
    var holdsToast: Bool = false

    /// No lesson running.
    static let inactive = TutorialSignals()
    var isCompleting: Bool { active && phase == .complete }
}

// MARK: - Coordinator

/// Runs the Getting Started tutorial: owns the synced progress, the active
/// lesson's step machine and (for lessons 2-3) the throwaway sandbox database.
///
/// Real screens never import this — they carry `.tutorialAnchor(_:)` tags and
/// call `tutorialCoach?.handle(_:)` at the actions a step waits for, both inert
/// when no lesson runs. Lesson 1 writes real tasks to the user's library;
/// lessons 2-3 run against `TutorialSandbox.database` and write nothing real.
@MainActor
final class TutorialCoordinator: ObservableObject {

    /// The synced progress (mirrors `UserPreferences.tutorialProgress`).
    @Published private(set) var progress: TutorialProgress
    /// The running lesson, if any.
    @Published private(set) var session: TutorialSession?
    /// The sandbox of the running lesson (lessons 2-3), else nil.
    private(set) var sandbox: TutorialSandbox?
    /// The sandbox database, injected into the lesson's screens.
    var sandboxDatabase: AppDatabase? { sandbox?.database }
    /// The lesson that just finished, until the tutorial board plays its pop.
    @Published private(set) var justCompleted: TutorialLessonID?

    /// How many sheet-level coach layers are on screen — the root layer only
    /// dims (and shows no fallback mark) while one of them owns the step.
    @Published private(set) var sheetLayerCount = 0

    private let database: AppDatabase
    private let userId: String?
    private let persists: Bool

    /// - Parameters:
    ///   - userId: The signed-in user; nil makes a preview coordinator.
    ///   - database: The user's real database (progress is written here).
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

    // MARK: Derived

    /// What real screens observe through the environment.
    var signals: TutorialSignals {
        guard let session else { return .inactive }
        let step = session.currentStep
        return TutorialSignals(
            active: true, step: session.step, phase: session.phase, sandboxed: sandbox != nil,
            closesSquareSheet: step?.closesSquareSheet ?? false, holdsToast: step?.holdsToast ?? false
        )
    }

    /// The instruction for the current step, with what the user just did folded in.
    var currentText: String? {
        guard let session, let step = session.currentStep else { return nil }
        switch step.dynamic {
        case .loggedSummary:
            guard let summary = session.logSummary else { return step.text }
            return session.logFinishedSquare
                ? "\(summary). The square is done; Undo stays here."
                : "\(summary). Undo stays here."
        case .poolFills:
            return session.poolSummary.map { "\($0). Tap Next." } ?? step.text
        case nil:
            return step.text
        }
    }

    // MARK: Progress

    /// Pulls in a progress value that changed elsewhere (a sync pull).
    func refresh(from remote: TutorialProgress) {
        if remote != progress { progress = remote }
    }

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

    /// Hides the Boards-tab card (allowed once the middle row is done).
    func dismissCard() {
        guard progress.canDismissCard, !progress.cardDismissed else { return }
        var next = progress
        next.cardDismissed = true
        persist(next)
    }

    /// Clears all progress and un-dismisses the card (the DEBUG reset).
    func reset() {
        session = nil
        sandbox = nil
        justCompleted = nil
        persist(.empty)
    }

    // MARK: Lesson lifecycle

    /// Opens a lesson: builds its sandbox (lessons 2-3), resumes at the saved
    /// step (or step 1 for a fresh / replayed one).
    /// - Returns: false when the sandbox could not be built or the lesson is Pro.
    @discardableResult
    func start(_ lesson: TutorialLessonID, user: User? = nil) -> Bool {
        guard lesson.isFree, session == nil else { return false }
        var sandboxForLesson: TutorialSandbox?
        if lesson == .createBoard || lesson == .completeBoard {
            guard let user = user ?? currentUserRow() else { return false }
            do {
                sandboxForLesson = try AppDatabase.seedTutorialSandbox(lesson: lesson, user: user)
            } catch {
                dlog("⚠️ TutorialCoordinator: sandbox seeding failed: \(error)")
                return false
            }
        }
        var step = 0
        var resumed = false
        if case .inProgress(let saved) = progress.state(of: lesson) {
            step = min(saved, max(TutorialCatalog.info(for: lesson).steps.count - 1, 0))
            resumed = step > 0
        }
        sandbox = sandboxForLesson
        session = TutorialSession(lesson: lesson, step: step, resumed: resumed, sampleBoardId: sandboxForLesson?.sampleBoardId)
        return true
    }

    private func currentUserRow() -> User? {
        guard let userId else { return nil }
        return try? database.fetchUser(id: userId)
    }

    /// An action step's event from a real control. Advances when it is the one
    /// the current step waits for.
    func handle(_ event: TutorialEvent) {
        guard var current = session, current.phase == .running else { return }
        // A moment closing always un-hides the coach layer, whatever the step.
        if event == .bingoMomentClosed || event == .greenlogMomentClosed {
            current.momentOpen = false
            session = current
        }
        guard let step = current.currentStep else { return }
        if step.advance == .action(event) {
            advance()
        } else if event == .greenlogMomentClosed, step.advance == .action(.bingoMomentClosed) {
            // The board finished before the Bingo beat was seen (squares done
            // out of order): the Greenlog closes the lesson.
            current.step = current.steps.count - 1
            session = current
            advance()
        }
    }

    /// The coach mark's Next on a read-only step.
    func next() {
        guard let current = session, current.phase == .running, current.currentStep?.advance == .next else { return }
        advance()
    }

    private func advance() {
        guard var current = session else { return }
        current.step += 1
        current.resumed = false
        if current.step >= current.steps.count {
            current.phase = .complete
            session = current
            var next = progress
            next.set(current.lesson, .done)
            persist(next)
        } else {
            session = current
        }
    }

    /// Whether the current step is read-only (shows Next).
    var currentStepIsReadOnly: Bool { session?.currentStep?.advance == .next }

    /// A sheet-level coach layer appeared.
    func sheetLayerAppeared() { sheetLayerCount += 1 }

    /// A sheet-level coach layer went away.
    func sheetLayerDisappeared() { sheetLayerCount = max(0, sheetLayerCount - 1) }

    // MARK: Step context from real controls

    /// A Bingo / Greenlog moment opened or closed over the lesson.
    func setMomentOpen(_ open: Bool) {
        guard var current = session, current.momentOpen != open else { return }
        current.momentOpen = open
        session = current
    }

    /// Lesson 3: a count log's outcome, for the next step's copy.
    func reportLog(summary: String, finishedSquare: Bool) {
        guard var current = session else { return }
        current.logSummary = summary
        current.logFinishedSquare = finishedSquare
        session = current
    }

    /// Lesson 2: the pulled pool's line for the "Tap Next" step.
    func reportPool(summary: String) {
        guard var current = session else { return }
        current.poolSummary = summary
        session = current
    }

    // MARK: Leaving

    /// The coach mark's ✕: asks before leaving.
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

    /// "Leave": saves the step (unless the lesson was already done), discards
    /// the sandbox and returns to the tutorial board.
    func leave() {
        guard let current = session else { return }
        if progress.state(of: current.lesson) != .done {
            var next = progress
            next.set(current.lesson, current.step == 0 ? .notStarted : .inProgress(step: current.step))
            if next != progress { persist(next) }
        }
        endSession()
    }

    /// "Back to the board" on the lesson-complete card.
    func finishCompletedLesson() {
        guard let current = session, current.phase == .complete else { return }
        justCompleted = current.lesson
        endSession()
    }

    /// The tutorial board played the square pop (and any Bingo toast).
    func consumeJustCompleted() {
        justCompleted = nil
    }

    private func endSession() {
        session = nil
        sandbox = nil
        // Sandbox boards' last-seen snapshots live in a throwaway suite.
        UserDefaults(suiteName: CounterArrivalStore.tutorialSuiteName)?
            .removePersistentDomain(forName: CounterArrivalStore.tutorialSuiteName)
    }
}

// MARK: - Environment

private struct TutorialCoachKey: EnvironmentKey {
    static let defaultValue: TutorialCoordinator? = nil
}

private struct TutorialSignalsKey: EnvironmentKey {
    static let defaultValue: TutorialSignals = .inactive
}

extension EnvironmentValues {
    /// The running tutorial's coordinator; nil outside a lesson, so every hook
    /// in a production view is inert by default.
    var tutorialCoach: TutorialCoordinator? {
        get { self[TutorialCoachKey.self] }
        set { self[TutorialCoachKey.self] = newValue }
    }

    /// Value-typed lesson state for views that react to it.
    var tutorialSignals: TutorialSignals {
        get { self[TutorialSignalsKey.self] }
        set { self[TutorialSignalsKey.self] = newValue }
    }
}

extension View {
    /// Dims and disables a control that the running lesson does not teach (it
    /// stays visible so the screen still reads like the real one).
    /// - Parameter active: true while a sandbox lesson runs.
    func tutorialDimmed(_ active: Bool) -> some View {
        opacity(active ? 0.45 : 1).allowsHitTesting(!active)
    }
}
