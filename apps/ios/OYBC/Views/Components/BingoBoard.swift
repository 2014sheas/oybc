import SwiftUI

/// Number of rows/columns in the grid
private let gridSize = 5

/// Total number of squares
private let totalSquares = gridSize * gridSize

/// Index of the center square (0-based)
private let centerIndex = totalSquares / 2

/// A 5x5 bingo board grid using LazyVGrid and BingoSquare components.
///
/// All squares are toggleable. The center square (Task 13) has special styling
/// with a thicker orange border and star indicator. Includes reset and fill-all
/// buttons for testing.
///
/// - Parameter squareSize: Width and height of each square in points (default: 60)
struct BingoBoard: View {
    /// Size of each square in points
    var squareSize: CGFloat = 60

    /// Tracks which squares are completed by index
    @State private var completedSquares: Set<Int> = []

    /// Grid column layout
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(squareSize), spacing: 4), count: gridSize)
    }

    /// Generate hardcoded task names
    private var taskNames: [String] {
        (1...totalSquares).map { "Task \($0)" }
    }

    /// Number of completed squares
    private var completedCount: Int {
        completedSquares.count
    }

    var body: some View {
        VStack(spacing: 16) {
            // Board grid
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<totalSquares, id: \.self) { index in
                    let isCenter = index == centerIndex
                    let taskName = isCenter ? "\(taskNames[index]) *" : taskNames[index]

                    BingoSquare(
                        taskName: taskName,
                        size: squareSize,
                        isCompletedBinding: Binding(
                            get: { completedSquares.contains(index) },
                            set: { _ in }
                        ),
                        onToggle: {
                            toggleSquare(index)
                        }
                    )
                    .overlay(
                        // Thicker orange border for center square
                        Group {
                            if isCenter {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.orange, lineWidth: 3)
                            }
                        }
                    )
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(uiColor: .systemGray5))
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("5 by 5 bingo board, \(completedCount) of \(totalSquares) completed")

            // Controls
            HStack {
                Text("\(completedCount) / \(totalSquares) completed")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 8) {
                    Button("Reset Board") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            completedSquares.removeAll()
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(uiColor: .systemGray6))
                    )
                    .accessibilityLabel("Reset all squares to incomplete")

                    Button("Fill All") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            completedSquares = Set(0..<totalSquares)
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(uiColor: .systemGray6))
                    )
                    .accessibilityLabel("Fill all squares as completed")
                }
            }
        }
    }

    /// Toggle a square's completed state by index.
    ///
    /// - Parameter index: The 0-based index of the square to toggle
    private func toggleSquare(_ index: Int) {
        if completedSquares.contains(index) {
            completedSquares.remove(index)
        } else {
            completedSquares.insert(index)
        }
    }
}

#Preview("Empty Board") {
    ScrollView {
        BingoBoard()
            .padding()
    }
}

#Preview("Large Squares") {
    ScrollView {
        BingoBoard(squareSize: 80)
            .padding()
    }
}
