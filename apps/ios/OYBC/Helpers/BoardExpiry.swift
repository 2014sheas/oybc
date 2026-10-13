import Foundation

/// "Expiring" board tag — when an active board is close enough to its end to
/// flag it (owner ruling 2026-10-13). The lead time scales with the board's
/// timeframe; a flat 24 h window tagged every daily board for its whole life.
///
/// Swift twin of `packages/shared/src/algorithms/boardExpiry.ts`; both run
/// `boardExpiryVectors.json`.
enum BoardExpiry {
    private static let hourMs: Double = 60 * 60 * 1000
    private static let dayMs: Double = 24 * hourMs

    /// A custom board's lead time is this share of its own length…
    static let customFraction = 0.1
    /// …clamped to [min, max] (min matches daily, max matches yearly).
    static let customMinMs = 3 * hourMs
    static let customMaxMs = 14 * dayMs

    /// The lead time before `endDate` at which this board reads "Expiring".
    ///
    /// - Returns: milliseconds, or `nil` for a board that never expires
    ///   (indefinite / no or unparseable `endDate`).
    static func leadMs(timeframe: Timeframe, startDate: String?, endDate: String?) -> Double? {
        guard timeframe != .indefinite,
              let endDate, let end = DateFormatting.parseISO(endDate) else { return nil }
        switch timeframe {
        case .daily: return 3 * hourMs
        case .weekly: return dayMs
        case .monthly: return 3 * dayMs
        case .yearly: return 14 * dayMs
        case .indefinite:
            return nil // unreachable — the guard above already returned
        case .custom:
            let start = startDate.flatMap(DateFormatting.parseISO)
            let lengthMs = start.map { end.timeIntervalSince($0) * 1000 }
            let lead = lengthMs.map { $0 > 0 ? $0 * customFraction : customMinMs } ?? customMinMs
            return min(customMaxMs, max(customMinMs, lead))
        }
    }

    /// Whether an active board is inside its "Expiring" lead time: its end
    /// is still ahead of `now` but within `leadMs`.
    ///
    /// - Parameter now: the screen's pinned instant (never a fresh clock read).
    static func isExpiringSoon(
        status: BoardStatus, timeframe: Timeframe, startDate: String?, endDate: String?, now: Date
    ) -> Bool {
        guard status == .active,
              let lead = leadMs(timeframe: timeframe, startDate: startDate, endDate: endDate),
              let endDate, let end = DateFormatting.parseISO(endDate) else { return false }
        let msLeft = end.timeIntervalSince(now) * 1000
        return msLeft >= 0 && msLeft < lead
    }

    /// `isExpiringSoon` for a stored board.
    static func isExpiringSoon(_ board: Board, now: Date) -> Bool {
        isExpiringSoon(
            status: board.status, timeframe: board.timeframe,
            startDate: board.startDate, endDate: board.endDate, now: now
        )
    }
}
