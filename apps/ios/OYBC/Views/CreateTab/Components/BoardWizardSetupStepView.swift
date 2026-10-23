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
///
/// Edit mode (Profile reorg PR3): a "Delete repeating board" danger row
/// sits at the bottom of the scrollable form. It lives on THIS step — the
/// one the editor lands on — rather than the last step because the stepper
/// only jumps backwards and the Pool step's Next is capacity-gated
/// (`.disabled(!canAdvance)`), so an under-filled repeating board could
/// never reach a Preview-step Delete. Web twin:
/// `BoardWizardSetupStep.onDeleteRepeatingBoard`.
struct BoardWizardSetupStepView: View {
    @Bindable var controller: BoardWizardViewModel
    let onCancel: () -> Void
    let onNext: () -> Void
    /// Profile reorg PR3 — "Delete repeating board". Rendered ONLY while
    /// the wizard is editing an existing repeating board
    /// (`controller.editingTemplateId != nil`) AND the parent wires it. The
    /// parent (`BoardWizardView`) owns the confirm `.alert` + the
    /// soft-delete; this step only asks.
    var onDeleteRepeatingBoard: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable form area
            ScrollView {
                VStack(spacing: 0) {
                    RisoBoardSetupForm(controller: controller)
                    if controller.editingTemplateId != nil, let onDeleteRepeatingBoard {
                        deleteRow(action: onDeleteRepeatingBoard)
                    }
                }
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

    /// Quiet red text action (the same treatment as CounterDetailView's
    /// Delete link — never a filled button), centred under the form. The
    /// 44pt hit shape is laid on a padded frame like the other quiet links.
    private func deleteRow(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Delete repeating board")
                .font(.risoHead(13, .bold))
                .foregroundStyle(Color.risoRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .accessibilityLabel("Delete repeating board")
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

                // Board Creation Split (iOS PR A) — accent tracks the
                // wizard's fixed mode: red one-off / blue recurring.
                RisoButton(title: "Next ›", kind: controller.isRecurring ? .blue : .primary, action: onNext)
                    .frame(maxWidth: .infinity)
                    // Visual dim + a real disabled state (so VoiceOver also
                    // reports/blocks it) when Step 1 isn't valid yet.
                    .opacity(controller.isStep1Valid ? 1 : 0.45)
                    .disabled(!controller.isStep1Valid)
            }
            .padding(.horizontal, Riso.gutter)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .background(Color.risoPaper)
        }
    }
}
