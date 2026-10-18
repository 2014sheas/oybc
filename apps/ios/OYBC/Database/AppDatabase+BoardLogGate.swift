import Foundation
import GRDB

// MARK: - Board log gate (survivor of the linked-counter heal file, slice 3a)

extension AppDatabase {

    /// Can a log made now still change this board? Credit toast + stepper
    /// hint qualify a board only when it is live, `.active`, not closed
    /// (`sealedAt == nil`) and not ended (`endDate` parses and is `< now` —
    /// compared as INSTANTS, never as strings). A closed or ended board's
    /// squares are frozen for new logs, so crediting it is a false claim.
    ///
    /// - Parameters:
    ///   - board: The candidate board.
    ///   - now: ISO8601 clock.
    /// - Returns: True when a log made at `now` can still move this board.
    static func boardCanStillCountLogs(_ board: Board, now: String) -> Bool {
        guard !board.isDeleted, board.status == .active, board.sealedAt == nil else { return false }
        if let endDate = board.endDate, let end = DateFormatting.parseISO(endDate),
           let nowDate = DateFormatting.parseISO(now), end < nowDate { return false }
        return true
    }
}
