import SwiftUI

/// A bingo board grid using LazyVGrid and BingoSquare components.
///
/// Supports 3x3, 4x4, and 5x5 grid sizes. All squares are toggleable.
/// For odd-sized grids, the center square has special styling with a
/// thicker orange border and star indicator. Includes reset and fill-all
/// buttons for testing. Detects completed bingo lines (rows, columns,
/// diagonals) and highlights them with a gold border. Displays a message
/// when bingo is achieved and "GREENLOG!" when all squares are complete.
///
/// Center square types:
/// - FREE: Auto-completed, shows "FREE SPACE", locked (cannot toggle off)
/// - CUSTOM_FREE: Auto-completed with custom text, locked
/// - CHOSEN: Fixed task name, NOT auto-completed, toggleable like any square
/// - NONE: Center is an ordinary square, no special treatment
///
/// - Parameters:
///   - gridSize: Number of rows/columns in the grid (default: 5)
///   - squareSize: Width and height of each square in points (default: 60)
///   - centerSquareType: Center square behavior type (default: .none)
///   - centerSquareCustomName: Custom name for .customFree type
struct BingoBoard: View {
    /// Number of rows/columns in the grid
    var gridSize: Int = 5

    /// Size of each square in points
    var squareSize: CGFloat = 60

    /// Center square type
    var centerSquareType: CenterSquareType = .none

    /// Custom name for customFree center square type
    var centerSquareCustomName: String? = nil

    /// Tracks which squares are completed by index
    @State private var completedSquares: Set<Int> = []

    /// Task names displayed on the board (shuffled via Fisher-Yates)
    @State private var taskNames: [String] = []

    /// Whether initial setup has been performed
    @State private var hasInitialized: Bool = false

    /// Total number of squares
    private var totalSquares: Int {
        gridSize * gridSize
    }

    /// Index of the center square (0-based), or -1 for even-sized grids
    private var centerIndex: Int {
        CenterSquare.getCenterSquareIndex(gridSize: gridSize)
    }

    /// Whether the center square is auto-completed (FREE or CUSTOM_FREE)
    private var isAutoCompleted: Bool {
        CenterSquare.isCenterAutoCompleted(centerSquareType)
    }

    /// Display text for the center square
    private var centerDisplayText: String {
        CenterSquare.getCenterDisplayText(type: centerSquareType, customName: centerSquareCustomName)
    }

    /// Grid column layout
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(squareSize), spacing: 4), count: gridSize)
    }

    /// Generate hardcoded task names
    private func generateTaskNames() -> [String] {
        (1...totalSquares).map { "Task \($0)" }
    }

    /// Number of completed squares
    private var completedCount: Int {
        completedSquares.count
    }

    /// Flat boolean completion grid built from the completed squares set.
    private var completionGrid: [Bool] {
        (0..<totalSquares).map { completedSquares.contains($0) }
    }

    /// Bingo detection result computed from the current completion state.
    private var bingoResult: BingoDetectionResult {
        BingoDetection.detectBingos(completionGrid: completionGrid, gridSize: gridSize)
    }

    /// Display message for bingo status (nil if no bingos).
    private var bingoMessage: String? {
        BingoDetection.formatBingoMessage(result: bingoResult)
    }

    /// Set of square indices that should be highlighted (part of a completed line).
    private var highlightedSquares: Set<Int> {
        BingoDetection.getHighlightedSquares(completedLines: bingoResult.completedLines, gridSize: gridSize)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Board grid
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<totalSquares, id: \.self) { index in
                    let isCenter = index == centerIndex
                    let isHighlighted = highlightedSquares.contains(index)
                    let name = index < taskNames.count ? taskNames[index] : "Task \(index + 1)"
                    let taskName: String = {
                        if isCenter && !centerDisplayText.isEmpty {
                            return centerDisplayText
                        } else if isCenter && centerSquareType == .none {
                            return name
                        } else if isCenter {
                            return "\(name) *"
                        }
                        return name
                    }()

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
                        Group {
                            if isHighlighted {
                                // Gold highlight for bingo line squares
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.yellow, lineWidth: 3)
                                    .shadow(color: Color.yellow.opacity(0.5), radius: 3)
                            } else if isCenter && centerSquareType != .none {
                                // Thicker orange border for special center squares (FREE, CUSTOM_FREE, CHOSEN)
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
            .accessibilityLabel("\(gridSize) by \(gridSize) bingo board, \(completedCount) of \(totalSquares) completed")

            // Bingo detection message
            if let message = bingoMessage {
                Text(message)
                    .font(bingoResult.isGreenlog ? .title2 : .headline)
                    .fontWeight(.bold)
                    .foregroundColor(bingoResult.isGreenlog ? .green : Color.yellow)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                bingoResult.isGreenlog ? Color.green : Color.yellow,
                                lineWidth: 2
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        bingoResult.isGreenlog
                                            ? Color.green.opacity(0.1)
                                            : Color.yellow.opacity(0.1)
                                    )
                            )
                    )
                    .accessibilityLabel(message)
            }

            // Controls
            VStack(spacing: 12) {
                Text("\(completedCount) / \(totalSquares) completed")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Button("Shuffle Board") {
                        shuffleBoard()
                    }
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(uiColor: .systemGray6))
                    )
                    .accessibilityLabel("Shuffle board task names and reset completion")

                    Button("Reset Board") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if centerIndex >= 0 && isAutoCompleted {
                                completedSquares = [centerIndex]
                            } else {
                                completedSquares.removeAll()
                            }
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
        .onAppear {
            if !hasInitialized {
                taskNames = generateTaskNames()
                if centerIndex >= 0 && isAutoCompleted {
                    completedSquares = [centerIndex]
                }
                hasInitialized = true
            }
        }
    }

    /// Toggle a square's completed state by index.
    /// Prevents toggling auto-completed center squares (FREE, CUSTOM_FREE).
    ///
    /// - Parameter index: The 0-based index of the square to toggle
    private func toggleSquare(_ index: Int) {
        if index == centerIndex && isAutoCompleted {
            return
        }
        if completedSquares.contains(index) {
            completedSquares.remove(index)
        } else {
            completedSquares.insert(index)
        }
    }

    /// Shuffle task names using Fisher-Yates algorithm and reset completion state.
    /// Preserves auto-completed center square.
    /// For CHOSEN type, keeps the center task fixed and only shuffles other squares.
    private func shuffleBoard() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if centerSquareType == .chosen && centerIndex >= 0 {
                let centerTask = taskNames[centerIndex]
                var otherTasks = taskNames.enumerated()
                    .filter { $0.offset != centerIndex }
                    .map { $0.element }
                otherTasks = Shuffle.fisherYatesShuffle(otherTasks)
                var newTasks = otherTasks
                newTasks.insert(centerTask, at: centerIndex)
                taskNames = newTasks
            } else {
                taskNames = Shuffle.fisherYatesShuffle(taskNames)
            }
            if centerIndex >= 0 && isAutoCompleted {
                completedSquares = [centerIndex]
            } else {
                completedSquares.removeAll()
            }
        }
    }
}

#Preview("5x5 Board") {
    ScrollView {
        BingoBoard()
            .padding()
    }
}

#Preview("3x3 Mini Board") {
    ScrollView {
        BingoBoard(gridSize: 3, squareSize: 90)
            .padding()
    }
}

#Preview("4x4 Standard Board") {
    ScrollView {
        BingoBoard(gridSize: 4, squareSize: 85)
            .padding()
    }
}

#Preview("5x5 Free Space") {
    ScrollView {
        BingoBoard(centerSquareType: .free)
            .padding()
    }
}

#Preview("5x5 Custom Free") {
    ScrollView {
        BingoBoard(centerSquareType: .customFree, centerSquareCustomName: "My Goal!")
            .padding()
    }
}
