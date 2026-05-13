import SwiftUI

/// Step number for the composite-task mini-wizard (1, 2, or 3).
typealias CompositeWizardStep = Int

private struct CompositeWizardStepInfo: Identifiable {
    let id: CompositeWizardStep
    let label: String
}

private let compositeWizardSteps: [CompositeWizardStepInfo] = [
    CompositeWizardStepInfo(id: 1, label: "Setup"),
    CompositeWizardStepInfo(id: 2, label: "Build"),
    CompositeWizardStepInfo(id: 3, label: "Review"),
]

/// CompositeWizardStepperView — 3-chip progress indicator for the
/// composite-task mini-wizard. iOS twin of web's
/// `CompositeWizardStepper`. Matches the board-wizard stepper visual
/// style for consistency; tapping a previous chip jumps back.
struct CompositeWizardStepperView: View {
    let currentStep: CompositeWizardStep
    var onStepClick: ((CompositeWizardStep) -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(compositeWizardSteps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(Color(.systemGray4))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                }

                let isActive = step.id == currentStep
                let isComplete = step.id < currentStep
                let isJumpable = step.id < currentStep && onStepClick != nil

                Button {
                    if isJumpable { onStepClick?(step.id) }
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(chipBackground(isActive: isActive, isComplete: isComplete))
                                .frame(width: 24, height: 24)
                            Group {
                                if isComplete {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                } else {
                                    Text("\(step.id)")
                                        .font(.system(size: 12, weight: .bold))
                                }
                            }
                            .foregroundColor(chipDotForeground(isActive: isActive, isComplete: isComplete))
                        }
                        Text(step.label)
                            .font(.system(size: 13, weight: isActive ? .bold : .medium))
                            .foregroundColor(chipForeground(isActive: isActive, isComplete: isComplete))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(chipFill(isActive: isActive, isComplete: isComplete))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(chipBorder(isActive: isActive, isComplete: isComplete), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isJumpable && !isActive)
                .accessibilityLabel("\(step.label) step\(isActive ? ", current" : isComplete ? ", complete" : "")")
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Chip palette (mirrors BoardWizardStepperView)

    private func chipFill(isActive: Bool, isComplete: Bool) -> Color {
        if isActive { return .blue }
        if isComplete { return Color.green.opacity(0.15) }
        return Color(.systemBackground)
    }

    private func chipBorder(isActive: Bool, isComplete: Bool) -> Color {
        if isActive { return .blue }
        if isComplete { return Color.green.opacity(0.4) }
        return Color(.systemGray4)
    }

    private func chipBackground(isActive: Bool, isComplete: Bool) -> Color {
        if isActive { return Color.white.opacity(0.25) }
        if isComplete { return .green }
        return Color(.systemGray5)
    }

    private func chipDotForeground(isActive: Bool, isComplete: Bool) -> Color {
        if isActive { return .white }
        if isComplete { return .white }
        return .secondary
    }

    private func chipForeground(isActive: Bool, isComplete: Bool) -> Color {
        if isActive { return .white }
        if isComplete { return .green }
        return .secondary
    }
}
