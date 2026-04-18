import SwiftUI

/// BoardWizardView — Orchestrator for the 3-step board-creation
/// wizard. iOS twin of web's `BoardWizardPage`.
///
/// Owns the wizard view-model and a `TaskLibraryViewModel`, then
/// routes them into the active step view. Step 3's full
/// implementation (real DB writes, navigation to the created board)
/// is split out into `BoardWizardPreviewStepStubView` for the
/// wizard-shell milestone; the full version replaces it in build
/// sequence step 3.
struct BoardWizardView: View {
    let userId: String
    let preferences: UserPreferences
    let onCancel: () -> Void
    let onComplete: (_ boardId: String, _ status: String) -> Void

    @State private var wizard: BoardWizardViewModel
    @State private var library = TaskLibraryViewModel()

    init(
        userId: String,
        preferences: UserPreferences,
        onCancel: @escaping () -> Void,
        onComplete: @escaping (_ boardId: String, _ status: String) -> Void
    ) {
        self.userId = userId
        self.preferences = preferences
        self.onCancel = onCancel
        self.onComplete = onComplete
        _wizard = State(initialValue: BoardWizardViewModel(preferences: preferences))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New board")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close wizard")
            }

            BoardWizardStepperView(
                currentStep: wizard.currentStep,
                onStepClick: { wizard.goToStep($0) }
            )

            stepContent
        }
        .onAppear {
            library.loadLibrary(userId: userId)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch wizard.currentStep {
        case 1:
            BoardWizardSetupStepView(
                controller: wizard,
                onCancel: onCancel,
                onNext: { wizard.goNext() }
            )
        case 2:
            BoardWizardTasksStepView(
                library: library,
                selectedTaskIds: $wizard.selectedTaskIds,
                tasksRequired: wizard.tasksRequired,
                centerTaskMode: wizard.centerMode,
                centerTaskId: $wizard.centerTaskId,
                userId: userId,
                onTaskCreated: { taskId, _, _ in
                    wizard.toggleTaskSelection(taskId)
                },
                onCompositeCreated: { _ in
                    // Composites can't be auto-selected (not boardable).
                },
                onLibraryReloadRequested: {
                    library.loadLibrary(userId: userId)
                },
                onBack: { wizard.goBack() },
                onNext: { wizard.goNext() }
            )
        default:
            BoardWizardPreviewStepView(
                controller: wizard,
                library: library,
                userId: userId,
                onBack: { wizard.goBack() },
                onComplete: { boardId, status in
                    onComplete(boardId, status.rawValue)
                }
            )
        }
    }
}
