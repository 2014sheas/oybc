import SwiftUI

/// BoardWizardSetupStepView — Step 1 of the wizard. iOS twin of web's
/// `BoardWizardSetupStep`. Renders `BoardSetupFormView` plus a footer
/// with Cancel and Next ›. The Next button reflects
/// `controller.isStep1Valid`.
///
/// The form's layout (one-off / recurring / core) is driven by the
/// controller's read-only `isRecurring` / `isCore` flags, both set at
/// wizard entry — there's no in-step timeframe lock or recurring toggle.
struct BoardWizardSetupStepView: View {
    @Bindable var controller: BoardWizardViewModel
    let onCancel: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BoardSetupFormView(controller: controller)

            Divider()

            HStack {
                if !controller.isStep1Valid, let msg = controller.step1ValidationMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .italic()
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Next ›", action: onNext)
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.isStep1Valid)
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
    }
}
