import SwiftUI

/// Increment/decrement control with min/max bounds.
///
/// Renders a − button, the current value, and a + button in a horizontal
/// row. Decrement is disabled at `min`; increment is disabled at `max`.
/// An optional trailing label can describe the value's context (e.g.
/// "of 5 subtasks"). Mirrors the web `CounterStepper` component in
/// `CounterStepper.tsx`.
///
/// - Parameters:
///   - value: Binding to the current integer value.
///   - min: Minimum allowed value — decrement button is disabled here.
///   - max: Maximum allowed value — increment button is disabled here.
///   - label: Optional trailing label shown after the value (e.g. "of 5 subtasks").
struct CounterStepperView: View {

    // MARK: - Parameters

    @Binding var value: Int
    let min: Int
    let max: Int
    var label: String? = nil

    // MARK: - Body

    var body: some View {
        HStack(spacing: 4) {
            // Decrement button
            Button {
                if value > min {
                    value -= 1
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(value <= min)

            // Current value
            Text("\(value)")
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 28)
                .multilineTextAlignment(.center)

            // Increment button
            Button {
                if value < max {
                    value += 1
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(value >= max)

            // Optional trailing label
            if let label {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Counter\(label.map { ", \($0)" } ?? "")")
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < max { value += 1 }
            case .decrement: if value > min { value -= 1 }
            @unknown default: break
            }
        }
    }
}

#Preview("With label") {
    struct Preview: View {
        @State private var n = 2
        var body: some View {
            CounterStepperView(value: $n, min: 1, max: 5, label: "of 5 subtasks")
                .padding()
        }
    }
    return Preview()
}

#Preview("Without label") {
    struct Preview: View {
        @State private var n = 1
        var body: some View {
            CounterStepperView(value: $n, min: 1, max: 10)
                .padding()
        }
    }
    return Preview()
}
