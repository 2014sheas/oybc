import Foundation

/// The board fields a derivation write owns (sync-churn fix). Swift twin of
/// `BoardDerivedState` in `packages/shared/src/algorithms/boardDerivedState.ts`,
/// pinned by the shared `boardDerivedStateVectors.json` fixture
/// (`BoardDerivedStateVectorTests`).
///
/// Every board derivation write (the live cascades, the pull cascades, the edit
/// cascades, the sealed re-derive) recomputes these from converged source data.
/// They used to be written unconditionally — each write bumped `version` +
/// `updatedAt` and enqueued a push even when nothing changed, so own-push
/// echoes on the pull path re-bumped and re-pushed every containing board and
/// versions climbed into the thousands. Callers now compare first and skip the
/// write, the bump AND the enqueue when nothing derived changed.
struct BoardDerivedState: Decodable {
    var completedTasks: Int?
    var totalTasks: Int?
    var linesCompleted: Int?
    var completedLineIds: [String]?
    var status: String?
    var completedAt: String?
    var sealedCompletedCells: [Int]?

    /// The derived slice of a stored board.
    init(board: Board) {
        completedTasks = board.completedTasks
        totalTasks = board.totalTasks
        linesCompleted = board.linesCompleted
        completedLineIds = board.completedLineIds
        status = board.status.rawValue
        completedAt = board.completedAt
        sealedCompletedCells = board.sealedCompletedCells
    }
}

/// True when writing `after` over `before` would change at least one derived
/// field. Same rules as the TypeScript twin:
/// - counts: absent = 0;
/// - `completedLineIds`: a set, absent = empty (iOS stores empty as NULL, web `[]`);
/// - `status`: strict equality;
/// - `completedAt`: absent / empty string = none;
/// - `sealedCompletedCells`: a set, but absent is DISTINCT from `[]`.
/// `version` / `updatedAt` are never compared.
///
/// - Parameters:
///   - before: The stored board's derived fields.
///   - after: The derived fields the write would persist.
/// - Returns: `true` if a write is needed, `false` if it would be a no-op.
func boardDerivedStateChanged(_ before: BoardDerivedState, _ after: BoardDerivedState) -> Bool {
    if (before.completedTasks ?? 0) != (after.completedTasks ?? 0) { return true }
    if (before.totalTasks ?? 0) != (after.totalTasks ?? 0) { return true }
    if (before.linesCompleted ?? 0) != (after.linesCompleted ?? 0) { return true }
    if Set(before.completedLineIds ?? []) != Set(after.completedLineIds ?? []) { return true }
    if before.status != after.status { return true }
    let beforeCompletedAt = (before.completedAt?.isEmpty ?? true) ? nil : before.completedAt
    let afterCompletedAt = (after.completedAt?.isEmpty ?? true) ? nil : after.completedAt
    if beforeCompletedAt != afterCompletedAt { return true }
    switch (before.sealedCompletedCells, after.sealedCompletedCells) {
    case (nil, nil): return false
    case let (b?, a?): return Set(b) != Set(a)
    default: return true
    }
}

extension Board {
    /// `true` when this board's derived fields differ from `other`'s — the
    /// compare-before-write gate every board derivation write passes through.
    func derivedStateDiffers(from other: Board) -> Bool {
        boardDerivedStateChanged(BoardDerivedState(board: other), BoardDerivedState(board: self))
    }

    /// Writes one derivation pass's stats + the greenlog status transition onto
    /// this board IN MEMORY (no persistence, no version / `updatedAt` bump —
    /// the caller compares with `derivedStateDiffers(from:)` first). The shared
    /// body of the live board cascades.
    ///
    /// - Parameters:
    ///   - update: The derivation output for this board.
    ///   - now: The `completedAt` stamp for a greenlog flip.
    /// - Returns: Whether the board flipped ACTIVE → COMPLETED or back.
    @discardableResult
    mutating func applyDerivedStats(
        _ update: DerivationPass.BoardStatsUpdate, now: String
    ) -> (didAutoComplete: Bool, wasReactivated: Bool) {
        let totalSquares = boardSize * boardSize
        let isGreenlogNow = update.completedTasks >= totalSquares
        completedTasks = update.completedTasks
        totalTasks = totalSquares
        linesCompleted = update.linesCompleted
        completedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
        if isGreenlogNow, status == .active {
            status = .completed
            completedAt = now
            return (true, false)
        }
        if !isGreenlogNow, status == .completed {
            status = .active
            completedAt = nil
            return (false, true)
        }
        return (false, false)
    }
}
