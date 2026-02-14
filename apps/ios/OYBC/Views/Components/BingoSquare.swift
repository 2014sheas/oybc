import SwiftUI

/// A single bingo board square that toggles between incomplete and completed states.
///
/// Supports tap to toggle, smooth animation, and full accessibility.
///
/// - Parameters:
///   - taskName: Text displayed in the square (default: "Task Name")
///   - initialCompleted: Whether the square starts completed (default: false)
///   - size: Width and height in points (default: 100)
struct BingoSquare: View {
    /// Display text for the square
    var taskName: String = "Task Name"

    /// Whether the square starts in a completed state
    var initialCompleted: Bool = false

    /// Size in points (width and height)
    var size: CGFloat = 100

    @State private var isCompleted: Bool = false

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
                    isCompleted.toggle()
                }
            }
            .accessibilityLabel("\(taskName) - \(isCompleted ? "completed" : "incomplete")")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isCompleted ? "completed" : "incomplete")
            .onAppear {
                isCompleted = initialCompleted
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
