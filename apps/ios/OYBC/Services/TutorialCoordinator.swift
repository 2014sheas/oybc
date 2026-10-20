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
    /// The current step's action happened; the lesson holds on its done line
    /// (every hole closed) until Next lights the next control.
    var awaitingNext: Bool = false
    /// Lesson 3: what the last log produced ("22 of 20"), for the step copy.
    var logSummary: String?
    /// Lesson 3: whether that log finished the square.
    var logFinishedSquare: Bool = false
    /// Lesson 2: the picked pool's line ("Fitness fills eight squares").
    var poolSummary: String?
    /// The sandbox's sample board id (lesson 3).
    var sampleBoardId: String?
    /// Lesson 3: row-major slots of the squares not yet complete, reported by the
    /// play board; the finale lights every one of them.
    var incompleteSlots: [Int]?
    /// Lesson 3: where each Sample week title sits right now, reported by the
    /// play board (Edit lets the person drag squares around).
    var slotByTitle: [String: Int]?

    /// The lesson's script.
    var steps: [TutorialStep] { TutorialCatalog.info(for: lesson).steps }

    /// The current step (nil once past the end).
    var currentStep: TutorialStep? { steps.indices.contains(step) ? steps[step] : nil }

    /// The step whose screen is up: the next one while the lesson waits for
    /// Next (its sheet may already be presented), else the current one.
    var screenStep: TutorialStep? {
        let index = awaitingNext ? step + 1 : step
        return steps.indices.contains(index) ? steps[index] : nil
    }

    /// The controls the current step lights: its anchors (a `.square` resolved
    /// to where its title sits now), or (finale) every still-incomplete square.
    /// Nothing while the lesson waits for Next.
    var litAnchors: [TutorialAnchorID] {
        guard !awaitingNext, let step = currentStep else { return [] }
        if step.litsIncompleteSquares, let slots = incompleteSlots, !slots.isEmpty {
            return slots.map { .square($0) }
        }
        return step.anchors.map { anchor in
            guard case .square(let seeded) = anchor, let slots = slotByTitle,
                  let title = TutorialCatalog.sampleTitle(atSeededSlot: seeded), let now = slots[title] else { return anchor }
            return .square(now)
        }
    }
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
    /// What a play-board square accepts right now (lesson 3): the one gesture
    /// the step teaches, nothing while the lesson waits for Next.
    var squareInteraction: TutorialSquareInteraction = .free

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

    /// The lesson is closing: the stage cover is animating out. The session and
    /// sandbox stay alive until `stageDidDismiss()` so nothing flashes or falls
    /// back to the real database mid-animation.
    @Published private(set) var isClosing = false

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
            closesSquareSheet: step?.closesSquareSheet ?? false, holdsToast: step?.holdsToast ?? false,
            squareInteraction: session.awaitingNext ? .none : (step?.squareInteraction ?? .none)
        )
    }

    /// The coach mark's line: the step's instruction, or its done line while
    /// the lesson waits for Next — either with what the user just did folded in.
    var currentText: String? {
        guard let session, let step = session.currentStep else { return nil }
        if session.awaitingNext {
            let fallback = step.doneText ?? step.text
            return dynamicText(step.doneDynamic, session: session, fallback: fallback)
        }
        return dynamicText(step.dynamic, session: session, fallback: step.text)
    }

    private func dynamicText(_ dynamic: TutorialStep.DynamicText?, session: TutorialSession, fallback: String) -> String {
        switch dynamic {
        case .loggedSummary:
            guard let summary = session.logSummary else { return fallback }
            return session.logFinishedSquare
                ? "\(summary). The square is done; Undo stays here."
                : "\(summary). Undo stays here."
        case .poolFills:
            return session.poolSummary.map { "\($0)." } ?? fallback
        case .remainingSquares:
            guard let left = session.incompleteSlots?.count, left > 0 else { return fallback }
            let word = BoardWizardTasksStepView.spelledCount(left)
            let head = word.prefix(1).uppercased() + word.dropFirst()
            return left == 1
                ? "\(head) left. Tap it to complete it."
                : "\(head) left. Tap each to complete it."
        case nil:
            return fallback
        }
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
        persist(.empty)
    }

    // MARK: Lesson lifecycle

    /// Opens a lesson: builds its sandbox (lessons 2-3), resumes at the saved
    /// step (or step 1 for a fresh / replayed one).
    /// - Returns: false when the sandbox could not be built or the lesson is Pro.
    @discardableResult
    func start(_ lesson: TutorialLessonID, user: User? = nil) -> Bool {
        guard lesson.isFree, session == nil else { return false }
        var saved = 0
        if case .inProgress(let savedStep) = progress.state(of: lesson) {
            saved = min(savedStep, max(TutorialCatalog.info(for: lesson).steps.count - 1, 0))
        }
        var sandboxForLesson: TutorialSandbox?
        if lesson == .createBoard || lesson == .completeBoard {
            guard let user = user ?? currentUserRow() else { return false }
            do {
                // Lesson 3 reseeds to the state its saved step implies.
                sandboxForLesson = try AppDatabase.seedTutorialSandbox(lesson: lesson, user: user, resumeStep: saved)
            } catch {
                dlog("⚠️ TutorialCoordinator: sandbox seeding failed: \(error)")
                return false
            }
        }
        sandbox = sandboxForLesson
        isClosing = false
        session = TutorialSession(
            lesson: lesson, step: TutorialCatalog.resumeStep(lesson: lesson, saved: saved),
            resumed: saved > 0, sampleBoardId: sandboxForLesson?.sampleBoardId
        )
        return true
    }

    /// The signed-in user's row from the real database (the sandbox gets a copy);
    /// nil for a preview coordinator or when the row is missing.
    private func currentUserRow() -> User? {
        guard let userId else { return nil }
        return try? database.fetchUser(id: userId)
    }

    /// An action step's event from a real control. When it is the one the
    /// current step waits for, the lesson holds on the step's done line until
    /// Next (or moves straight on when the step has none: the next step is
    /// read-only, or the lesson completes). No other event moves the lesson
    /// forward — a step is never skipped — and a lit sheet closing early
    /// steps back to the control that reopens it.
    func handle(_ event: TutorialEvent) {
        guard var current = session, current.phase == .running, !isClosing else { return }
        // A moment closing always un-hides the coach layer, whatever the step.
        if event == .bingoMomentClosed || event == .greenlogMomentClosed {
            current.momentOpen = false
            session = current
        }
        guard let step = current.currentStep else { return }
        if current.awaitingNext {
            // Every hole is closed; only a retreat for the step about to light
            // (its sheet handed off before Next) means anything.
            if let back = TutorialCatalog.retreat(lesson: current.lesson, step: current.step + 1, event: event) {
                retreat(to: back)
            }
            return
        }
        if step.advance == .action(event) {
            if step.doneText != nil, current.step + 1 < current.steps.count {
                current.awaitingNext = true
                current.resumed = false
                session = current
                recordStep(current.lesson, step: current.step + 1)
            } else {
                advance()
            }
        } else if let back = TutorialCatalog.retreat(lesson: current.lesson, step: current.step, event: event) {
            retreat(to: back)
        }
    }

    /// Steps back to `step` (the control that reopens a dismissed sheet).
    private func retreat(to step: Int) {
        guard var current = session else { return }
        current.step = step
        current.awaitingNext = false
        current.resumed = false
        session = current
        recordStep(current.lesson, step: step)
    }

    /// The coach mark's Next: lights the next control after a done line, or
    /// advances a read-only step.
    func next() {
        guard var current = session, current.phase == .running, !isClosing else { return }
        if current.awaitingNext {
            current.awaitingNext = false
            session = current
            advance()
            return
        }
        guard current.currentStep?.advance == .next else { return }
        advance()
    }

    /// Moves to the next step. Past the last step the lesson completes and is
    /// saved as done; otherwise the new place is saved so "Your place is saved"
    /// holds even if the app is killed (`recordStep` never lowers or rewrites a
    /// finished lesson).
    private func advance() {
        guard var current = session else { return }
        current.step += 1
        current.resumed = false
        if current.step >= current.steps.count {
            current.phase = .complete
            session = current
            var next = progress
            next.set(current.lesson, .done)
            if next != progress { persist(next) }
        } else {
            session = current
            recordStep(current.lesson, step: current.step)
        }
    }

    /// Whether the current step is read-only (shows Next).
    var currentStepIsReadOnly: Bool { session?.currentStep?.advance == .next }

    /// Whether the coach mark shows Next: a read-only step, or a done line.
    var showsNext: Bool { (session?.awaitingNext ?? false) || currentStepIsReadOnly }

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

    /// Lesson 3: the slots of the squares not yet complete (finale lights them all).
    func reportIncomplete(slots: [Int]) {
        guard var current = session, current.incompleteSlots != slots else { return }
        current.incompleteSlots = slots
        session = current
    }

    /// Lesson 3: where each placed title sits now, so a `.square` anchor follows
    /// its square after an Edit move.
    func reportSlots(byTitle slots: [String: Int]) {
        guard var current = session, current.slotByTitle != slots else { return }
        current.slotByTitle = slots
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

    /// "Leave": saves the step (never lowering it, never touching a finished
    /// lesson) and closes the stage. The session and sandbox stay alive until
    /// `stageDidDismiss()`.
    func leave() {
        guard let current = session else { return }
        recordStep(current.lesson, step: current.step)
        var ending = current
        ending.phase = .running
        session = ending
        isClosing = true
    }

    /// "Back to the board" on the lesson-complete card.
    func finishCompletedLesson() {
        guard let current = session, current.phase == .complete else { return }
        justCompleted = current.lesson
        isClosing = true
    }

    /// The tutorial board played the square pop (and any Bingo toast).
    func consumeJustCompleted() {
        justCompleted = nil
    }

    /// The stage cover finished dismissing (any way it was dismissed). A lesson
    /// still running is left first so its place is saved, then the session,
    /// sandbox and its throwaway defaults are torn down.
    func stageDidDismiss() {
        if session != nil, !isClosing { leave() }
        tearDown()
    }

    /// Drops the session and sandbox and clears the sandbox boards' throwaway
    /// last-seen snapshots. Runs only after the cover is gone, so no view ever
    /// reads a missing sandbox (or falls back to the real database) mid-animation.
    private func tearDown() {
        session = nil
        sandbox = nil
        isClosing = false
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
