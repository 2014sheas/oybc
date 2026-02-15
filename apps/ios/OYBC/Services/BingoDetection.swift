import Foundation

/// Result of bingo detection on a board.
///
/// - `completedLines`: Array of line IDs that are complete (e.g., "row_0", "col_2", "diag_main")
/// - `isGreenlog`: True when ALL squares on the board are completed
/// - `totalCompleted`: Number of completed squares
/// - `totalSquares`: Total squares on the board (gridSize * gridSize)
struct BingoDetectionResult {
    let completedLines: [String]
    let isGreenlog: Bool
    let totalCompleted: Int
    let totalSquares: Int
}

/// Bingo detection algorithm for OYBC boards.
///
/// Provides functions to detect completed lines, format messages,
/// and determine which squares to highlight. Mirrors the TypeScript
/// implementation in packages/shared for cross-platform consistency.
enum BingoDetection {

    /// Detect all completed bingo lines on a board.
    ///
    /// Checks all rows, columns, and diagonals for completion.
    /// Returns all simultaneously completed lines and whether the
    /// entire board is complete (GREENLOG).
    ///
    /// The completion grid is a flat boolean array of length gridSize * gridSize,
    /// indexed row-major: index = row * gridSize + col.
    ///
    /// Line ID format:
    /// - Rows: "row_0", "row_1", ... "row_{n-1}"
    /// - Columns: "col_0", "col_1", ... "col_{n-1}"
    /// - Main diagonal (top-left to bottom-right): "diag_main"
    /// - Anti diagonal (top-right to bottom-left): "diag_anti"
    ///
    /// - Parameters:
    ///   - completionGrid: Flat boolean array of completed states (row-major order)
    ///   - gridSize: Board size (3, 4, or 5)
    /// - Returns: BingoDetectionResult with all detected lines and greenlog status
    static func detectBingos(completionGrid: [Bool], gridSize: Int) -> BingoDetectionResult {
        let totalSquares = gridSize * gridSize

        precondition(
            completionGrid.count == totalSquares,
            "completionGrid length (\(completionGrid.count)) does not match gridSize * gridSize (\(totalSquares))"
        )

        var completedLines: [String] = []
        var totalCompleted = 0

        // Count total completed squares
        for i in 0..<totalSquares {
            if completionGrid[i] {
                totalCompleted += 1
            }
        }

        // Check rows
        for row in 0..<gridSize {
            var rowComplete = true
            for col in 0..<gridSize {
                if !completionGrid[row * gridSize + col] {
                    rowComplete = false
                    break
                }
            }
            if rowComplete {
                completedLines.append("row_\(row)")
            }
        }

        // Check columns
        for col in 0..<gridSize {
            var colComplete = true
            for row in 0..<gridSize {
                if !completionGrid[row * gridSize + col] {
                    colComplete = false
                    break
                }
            }
            if colComplete {
                completedLines.append("col_\(col)")
            }
        }

        // Check main diagonal (top-left to bottom-right)
        var mainDiagComplete = true
        for i in 0..<gridSize {
            if !completionGrid[i * gridSize + i] {
                mainDiagComplete = false
                break
            }
        }
        if mainDiagComplete {
            completedLines.append("diag_main")
        }

        // Check anti diagonal (top-right to bottom-left)
        var antiDiagComplete = true
        for i in 0..<gridSize {
            if !completionGrid[i * gridSize + (gridSize - 1 - i)] {
                antiDiagComplete = false
                break
            }
        }
        if antiDiagComplete {
            completedLines.append("diag_anti")
        }

        let isGreenlog = totalCompleted == totalSquares

        return BingoDetectionResult(
            completedLines: completedLines,
            isGreenlog: isGreenlog,
            totalCompleted: totalCompleted,
            totalSquares: totalSquares
        )
    }

    /// Format a bingo detection result into a display message.
    ///
    /// Returns a human-readable string describing the bingo state:
    /// - "GREENLOG!" when all squares are complete
    /// - "Bingo! (row_0, col_2)" when one or more lines are complete
    /// - nil when no lines are complete
    ///
    /// - Parameter result: BingoDetectionResult from detectBingos
    /// - Returns: Display message string, or nil if no bingos detected
    static func formatBingoMessage(result: BingoDetectionResult) -> String? {
        if result.isGreenlog {
            return "GREENLOG!"
        }

        if result.completedLines.isEmpty {
            return nil
        }

        return "Bingo! (\(result.completedLines.joined(separator: ", ")))"
    }

    /// Get the set of square indices that belong to completed bingo lines.
    ///
    /// Used for visual highlighting of squares that are part of a winning line.
    ///
    /// - Parameters:
    ///   - completedLines: Array of line IDs (e.g., ["row_0", "diag_main"])
    ///   - gridSize: Board size (3, 4, or 5)
    /// - Returns: Set of 0-based square indices that are part of completed lines
    static func getHighlightedSquares(completedLines: [String], gridSize: Int) -> Set<Int> {
        var highlighted = Set<Int>()

        for lineId in completedLines {
            if lineId.hasPrefix("row_"), let row = Int(lineId.dropFirst(4)) {
                for col in 0..<gridSize {
                    highlighted.insert(row * gridSize + col)
                }
            } else if lineId.hasPrefix("col_"), let col = Int(lineId.dropFirst(4)) {
                for row in 0..<gridSize {
                    highlighted.insert(row * gridSize + col)
                }
            } else if lineId == "diag_main" {
                for i in 0..<gridSize {
                    highlighted.insert(i * gridSize + i)
                }
            } else if lineId == "diag_anti" {
                for i in 0..<gridSize {
                    highlighted.insert(i * gridSize + (gridSize - 1 - i))
                }
            }
        }

        return highlighted
    }
}
