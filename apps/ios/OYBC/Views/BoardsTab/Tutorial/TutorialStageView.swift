import SwiftUI

/// The full-screen "lesson stage": hosts the REAL screen a lesson teaches over
/// the right database (the user's own for lesson 1, the throwaway sandbox for
/// lessons 2-3), with the walkthrough layers above it. Presented from the
/// tutorial board as a full-screen cover.
///
/// Deviation from "navigates to the lesson's tab": the stage mounts the real
/// view (`TasksTabView`, `CreateHubView`, `BoardPlayView`) in its own
/// `NavigationStack` instead of driving the live tab bar, so a lesson can never
/// strand the user in another tab and the sandbox database reaches every
/// screen it needs through plain injection.
struct TutorialStageView: View {
    let lesson: TutorialLessonID

    @EnvironmentObject private var coach: TutorialCoordinator
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var tasksPath = NavigationPath()

    var body: some View {
        ZStack {
            lessonScreen
            if let session = coach.session, session.phase == .complete, !coach.isClosing {
                completeOverlay(session)
            }
        }
        .preferredColorScheme(forcedColorScheme)
        .environment(\.tutorialCoach, coach)
        .environment(\.tutorialSignals, coach.signals)
        .environment(\.appDatabase, coach.sandboxDatabase ?? .shared)
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

    // MARK: Screens

    @ViewBuilder
    private var lessonScreen: some View {
        let userId = authService.currentUser?.id ?? ""
        switch lesson {
        case .createTask:
            NavigationStack(path: $tasksPath) {
                TasksTabView(userId: userId, path: $tasksPath, onOpenBoard: { _ in })
                    .tutorialCoachLayer(isRoot: true)
            }
        case .createBoard:
            NavigationStack {
                CreateHubView(
                    userId: userId,
                    preferences: sandboxPreferences,
                    onBoardCompleted: { _, _ in },
                    database: coach.sandboxDatabase ?? .shared
                )
                .tutorialCoachLayer(isRoot: true)
            }
        case .completeBoard:
            NavigationStack {
                if let boardId = coach.session?.sampleBoardId, let database = coach.sandboxDatabase {
                    BoardPlayView(boardId: boardId, embedded: true, database: database)
                        .tutorialCoachLayer(isRoot: true)
                }
            }
        default:
            EmptyView()
        }
    }

    /// The wizard's defaults inside lesson 2: a 3×3 with a free space, so one
    /// supplied pool fills the board.
    private var sandboxPreferences: UserPreferences {
        var prefs = authService.userPreferences
        prefs.defaultBoardSize = .three
        prefs.defaultCenterType = .free
        return prefs
    }

    // MARK: Lesson complete

    private func completeOverlay(_ session: TutorialSession) -> some View {
        ZStack {
            TutorialScrimShape.color.ignoresSafeArea()
            TutorialLessonCompleteCard(
                subtitle: TutorialCatalog.info(for: session.lesson).completeSubtitle,
                onBack: { coach.finishCompletedLesson() }
            )
        }
        .transition(.opacity)
    }
}
