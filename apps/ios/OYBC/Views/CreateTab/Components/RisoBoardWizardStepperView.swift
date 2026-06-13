import SwiftUI

// MARK: - Step info

private struct WizardStepItem: Identifiable {
    let id: WizardStep   // 1/2/3
    let label: String
}

private let risoWizardSteps: [WizardStepItem] = [
    WizardStepItem(id: 1, label: "Setup"),
    WizardStepItem(id: 2, label: "Tasks"),
    WizardStepItem(id: 3, label: "Preview"),
]

// MARK: - RisoBoardWizardStepperView

/// Riso-styled 3-step progress bar for the board-creation wizard.
///
/// CSS equivalent: `.r-stepper-bar`, `.r-step`, `.r-step-dot`, `.r-step-lbl`,
/// `.r-step-line`. Spec:
///   - Three 26pt circles, 2px ink keyline.
///   - Active = red fill, paper text.
///   - Done = green fill, paper text + checkmark.
///   - Inactive = paper2 fill, muted text.
///   - Connectors = 2px 25%-ink lines (flex, fills available space).
///   - Labels below each dot: Bricolage 700 12px, muted inactive / ink active.
///   - Tapping a completed step jumps back (same as existing `BoardWizardStepperView`).
struct RisoBoardWizardStepperView: View {
    let currentStep: WizardStep
    var onStepClick: ((WizardStep) -> Void)? = nil
    var readOnly: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(risoWizardSteps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    // 2px connector at 25% ink opacity
                    Rectangle()
                        .fill(Color.risoInk.opacity(0.25))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        // Align the connector to mid-dot height (dot=26, label below)
                        .padding(.bottom, 16)
                }

                stepItem(step: step)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func stepItem(step: WizardStepItem) -> some View {
        let isActive   = step.id == currentStep
        let isDone     = step.id < currentStep
        let isJumpable = !readOnly && isDone && onStepClick != nil

        Button {
            if isJumpable { onStepClick?(step.id) }
        } label: {
            VStack(spacing: 4) {
                // 26pt circle
                ZStack {
                    Circle()
                        .fill(dotFill(isActive: isActive, isDone: isDone))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                        )

                    Group {
                        if isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                        } else {
                            Text("\(step.id)")
                                .font(.risoHead(12, .extraBold))
                        }
                    }
                    .foregroundStyle(dotForeground(isActive: isActive, isDone: isDone))
                }

                // Step label
                Text(step.label)
                    .font(.risoHead(12, .bold))
                    .foregroundStyle(isActive ? Color.risoInk : Color.risoMuted)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isJumpable && !isActive)
        .accessibilityLabel("\(step.label) step\(isActive ? ", current" : isDone ? ", complete" : "")")
    }

    // MARK: - Colors

    private func dotFill(isActive: Bool, isDone: Bool) -> Color {
        if isActive { return .risoRed }
        if isDone   { return .risoGreen }
        return .risoPaper2
    }

    private func dotForeground(isActive: Bool, isDone: Bool) -> Color {
        if isActive || isDone { return .risoPaper }
        return .risoMuted
    }
}
