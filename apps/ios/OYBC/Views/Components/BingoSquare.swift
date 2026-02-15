import SwiftUI

/// A single bingo board square that toggles between incomplete and completed states.
///
/// Supports tap to toggle, smooth animation, and full accessibility.
/// Can be used in uncontrolled mode (manages own state) or controlled mode
/// (parent manages state via isCompletedBinding and onToggle).
///
/// - Parameters:
///   - taskName: Text displayed in the square (default: "Task Name")
///   - initialCompleted: Whether the square starts completed (default: false)
///   - size: Width and height in points (default: 100)
///   - isCompletedBinding: Optional binding for controlled mode
///   - onToggle: Optional callback when the square is toggled
struct BingoSquare: View {
    /// Display text for the square
    var taskName: String = "Task Name"

    /// Whether the square starts in a completed state (uncontrolled mode)
    var initialCompleted: Bool = false

    /// Size in points (width and height)
    var size: CGFloat = 100

    /// Optional binding for controlled mode (parent manages state)
    var isCompletedBinding: Binding<Bool>?

    /// Optional callback when the square is toggled
    var onToggle: (() -> Void)?

    @State private var internalCompleted: Bool = false

    /// The current completed state, from binding or internal state
    private var isCompleted: Bool {
        isCompletedBinding?.wrappedValue ?? internalCompleted
    }

    var body: some View {
        Text(taskName)
            .font(.system(size: 14, weight: .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .foregroundColor(isCompleted ? .white : .primary)
            .padding(8)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCompleted ? Color.green : Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isCompleted ? Color.green.opacity(0.8) : Color(.systemGray4), lineWidth: 2)
            )
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if let onToggle = onToggle {
                        onToggle()
                    } else {
                        internalCompleted.toggle()
                    }
                }
            }
            .accessibilityLabel("\(taskName) - \(isCompleted ? "completed" : "incomplete")")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isCompleted ? "completed" : "incomplete")
            .onAppear {
                if isCompletedBinding == nil {
                    internalCompleted = initialCompleted
                }
            }
    }
}

#Preview("Default") {
    BingoSquare()
}

#Preview("Completed") {
    BingoSquare(initialCompleted: true)
}

#Preview("Large") {
    BingoSquare(size: 150)
}
