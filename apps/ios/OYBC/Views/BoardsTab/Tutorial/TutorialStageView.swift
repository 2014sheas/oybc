import SwiftUI

/// The full-screen "lesson stage" (handoff `README` §The tutorial stage): the
/// ink tutorial bar over a tutorial-owned FACSIMILE of the app screen, fed by
/// the lesson's fixture, with the scrim + ring + coach mark above it. Exactly
/// one control per step is wired; everything else is drawn inert. The ✕ in the
/// bar is the only way out (no interactive dismiss, no system back). Presented
/// from the tutorial board as a full-screen cover after the start sheet.
struct TutorialStageView: View {
    let lesson: TutorialLessonID

    @EnvironmentObject private var coach: TutorialCoordinator
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    /// The "Leave this lesson?" sheet (raised from the bar's ✕).
    @State private var confirmingLeave = false

    var body: some View {
        VStack(spacing: 0) {
            if let session = coach.session {
                TutorialBar(
                    label: session.info.barLabel,
                    step: session.step,
                    stepCount: session.steps.count,
                    onExit: {
                        // Over the complete card the lesson is done: ✕ is "Back to the board".
                        if session.phase == .complete {
                            coach.finishCompletedLesson(exit: .board)
                        } else {
                            confirmingLeave = true
                            coach.requestLeave()
                        }
                    }
                )
                ZStack {
                    // The real screens run under the home indicator (their tab
                    // bars and footers carry that padding), so the facsimile does too.
                    facsimile(session)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .tutorialSpotlight(coach: coach)
                    if session.phase == .complete, !coach.isClosing {
                        completeOverlay(session)
                    }
                }
                .clipped()
            }
        }
        .background(Color.risoPaper.ignoresSafeArea())
        .preferredColorScheme(forcedColorScheme)
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $confirmingLeave, onDismiss: {
            if coach.session?.phase == .confirmingLeave { coach.keepGoing() }
        }) {
            TutorialLeaveSheet(
                step: coach.session?.step ?? 0,
                onKeepGoing: { confirmingLeave = false },
                onLeave: { confirmingLeave = false; coach.leave() }
            )
            .presentationDetents([.medium])
            .interactiveDismissDisabled(false)
        }
        .onChange(of: coach.isClosing) { _, closing in
            if closing { dismiss() }
        }
    }

    /// The app's theme override (a presented cover does not inherit it).
    private var forcedColorScheme: ColorScheme? {
        switch authService.userPreferences.theme {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    // MARK: Facsimiles

    @ViewBuilder
    private func facsimile(_ session: TutorialSession) -> some View {
        switch session.state {
        case .createTask(let state):
            TutorialCreateTaskLesson(state: state, step: session.step, perform: { coach.perform($0) })
        case .createBoard(let state):
            TutorialCreateBoardLesson(state: state, step: session.step, perform: { coach.perform($0) })
        case .completeBoard(let state):
            TutorialCompleteBoardLesson(state: state, step: session.step, perform: { coach.perform($0) })
        }
    }

    // MARK: Lesson complete

    private func completeOverlay(_ session: TutorialSession) -> some View {
        ZStack {
            TutorialScrimShape.color.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            TutorialLessonCompleteCard(
                subtitle: completeSubtitle(session),
                secondary: session.info.completeSecondary,
                onBack: { coach.finishCompletedLesson(exit: .board) },
                onSecondary: { exit in coach.finishCompletedLesson(exit: exit) }
            )
        }
        .transition(.opacity)
    }

    /// Lesson 1 names the two tasks it wrote; the others use their fixed line.
    private func completeSubtitle(_ session: TutorialSession) -> String {
        if case .createTask(let s) = session.state, let added = s.addedTitle, let counting = s.countingTitle {
            return "\(added) and \(counting) are in your library."
        }
        return session.info.completeSubtitle
    }
}
