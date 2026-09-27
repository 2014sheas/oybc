import Foundation

/// Center square helper algorithms for OYBC boards.
///
/// Provides functions to determine center square index, auto-completion
/// behavior, and display text. Mirrors the TypeScript implementation
/// in `packages/bingo-core/src/centerSquare.ts` for
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
    /// CHOSEN (legacy — see ``effectiveCenter(_:)``) and NONE are not auto-completed.
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

    /// The center type a live board BEHAVES as (Board Edit slice 3, D1).
    ///
    /// CHOSEN is legacy: slice 3 retired it in favour of per-square locks. It
    /// is never migrated on disk (sealed rows must not mutate, and older peers
    /// still write it); every consumer reads it through this function, which
    /// maps CHOSEN → NONE. Paired with
    /// ``isLegacyChosenCenterLocked(centerType:row:col:gridSize:)``, a CHOSEN
    /// board reads as "task-square center + locked center placement".
    /// Twin of `@oybc/bingo-core` `effectiveCenter`.
    ///
    /// - Parameter type: The stored center square type.
    /// - Returns: `.free` or `.none` — never `.chosen`.
    static func effectiveCenter(_ type: CenterSquareType) -> CenterSquareType {
        type == .free ? .free : .none
    }

    /// Whether a stored center type is the legacy CHOSEN value (D2: the
    /// squares Save converts such a row once). Twin of `isLegacyChosen`.
    ///
    /// - Parameter type: The stored center square type.
    /// - Returns: True iff `type` is `.chosen`.
    static func isLegacyChosen(_ type: CenterSquareType) -> Bool {
        type == .chosen
    }

    /// Whether a placement at `(row, col)` is implicitly locked because its
    /// board is legacy CHOSEN and the placement sits at the positional center
    /// (D1). Effective lock = `boardTask.isLocked || isLegacyChosenCenterLocked(...)`.
    /// Twin of `@oybc/bingo-core` `isLegacyChosenCenterLocked`.
    ///
    /// - Parameters:
    ///   - centerType: The board's stored center square type.
    ///   - row: Placement row (0-based).
    ///   - col: Placement column (0-based).
    ///   - gridSize: Board size (odd sizes have a positional center).
    /// - Returns: True iff CHOSEN and `(row, col)` is the positional center.
    static func isLegacyChosenCenterLocked(
        centerType: CenterSquareType,
        row: Int,
        col: Int,
        gridSize: Int
    ) -> Bool {
        guard centerType == .chosen else { return false }
        let centerIndex = getCenterSquareIndex(gridSize: gridSize)
        guard centerIndex >= 0 else { return false }
        return row * gridSize + col == centerIndex
    }
}
