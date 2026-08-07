import Foundation

/// Center square helper algorithms for OYBC boards.
///
/// Provides functions to determine center square index, auto-completion
/// behavior, and display text. Mirrors the TypeScript implementation
/// in `packages/shared/src/algorithms/centerSquare.ts` for
/// cross-platform consistency.
enum CenterSquare {

    /// Get center square index for a board size.
    ///
    /// Returns the 0-based flat index of the center square for odd-sized boards.
    /// Returns -1 for even-sized boards (no center square).
    ///
    /// - Parameter gridSize: Board size (3, 4, or 5)
    /// - Returns: Center square index, or -1 for even-sized boards
    static func getCenterSquareIndex(gridSize: Int) -> Int {
        if gridSize % 2 == 0 { return -1 }
        return (gridSize * gridSize) / 2
    }

    /// Check if center square should be auto-completed.
    ///
    /// FREE is auto-completed and locked (cannot toggle off).
    /// CHOSEN and NONE types are not auto-completed.
    ///
    /// - Parameter type: The center square type
    /// - Returns: True if the center square should be auto-completed
    static func isCenterAutoCompleted(_ type: CenterSquareType) -> Bool {
        return type == .free
    }

    /// Get display text for center square.
    ///
    /// Returns the appropriate label text based on the center square type:
    /// - FREE: "FREE SPACE"
    /// - CHOSEN: empty string (uses task name from board data)
    /// - NONE: empty string (ordinary square)
    ///
    /// - Parameter type: The center square type
    /// - Returns: Display text for the center square
    static func getCenterDisplayText(type: CenterSquareType) -> String {
        switch type {
        case .free:
            return "FREE SPACE"
        case .chosen, .none:
            return ""
        }
    }
}
