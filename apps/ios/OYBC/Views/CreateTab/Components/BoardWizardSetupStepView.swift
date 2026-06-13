import SwiftUI

/// BoardWizardSetupStepView — Step 1 of the wizard.
///
/// **Riso reskin**: renders `RisoBoardSetupForm` (the new wizard-only Riso
/// styled form) + a Riso-styled footer row (Cancel / Next ›). The shared
/// `BoardSetupFormView` is NOT used here — it remains untouched for
/// `EditBoardSheet` and its existing snapshot coverage.
///
/// All VM bindings and validation behaviour (`controller.isStep1Valid`,
/// `controller.step1ValidationMessage`) are preserved unchanged.
struct BoardWizardSetupStepView: View {
    @Bindable var controller: BoardWizardViewModel
    let onCancel: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable form area
            ScrollView {
                RisoBoardSetupForm(controller: controller)
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
            }

            // Validation message (above footer)
            if !controller.isStep1Valid, let msg = controller.step1ValidationMessage {
                Text(msg)
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoRed)
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Footer buttons
            risoFooter
        }
    }

    @ViewBuilder
    private var risoFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.risoInk)
                .frame(height: Riso.Keyline.container)

            HStack(spacing: 10) {
                RisoButton(title: "Cancel", kind: .neutral, action: onCancel)
                    .frame(maxWidth: .infinity)

                RisoButton(title: "Next ›", kind: .primary, action: onNext)
                    .frame(maxWidth: .infinity * 1.7)
                    .opacity(controller.isStep1Valid ? 1 : 0.45)
                    .allowsHitTesting(controller.isStep1Valid)
            }
            .padding(.horizontal, Riso.gutter)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .background(Color.risoPaper)
        }
    }
}
