import Foundation

// MARK: - Windowed linked counters — what survives of the heal (slice 3a)
//
// Swift twin of `packages/shared/src/algorithms/linkedCounterWindowHeal.ts`.
// The heal planner, its copy draft and plan types were retired by
// TASK_WINDOW_REWORK slice 3a (writers stop minting; the slice-4 sweep
// repoints stamped rows). Only the two window-match predicates remain.

extension BoardSources {
    /// Do two stored `startDate`s name the same window opening?
    ///
    /// `Board.startDate` has TWO live encodings — the offset-less local ISO
    /// the wizard writes (`2026-09-18T00:00:00`) and the full UTC form a sync
    /// round-trip can hand back — and a derived row copies whichever one its
    /// board carried at mint time. Those never compare equal as strings, so a
    /// plain `==` would answer "not mine" for a re-encoded pull. Comparing
    /// INSTANTS is what makes the two encodings agree; a stamp that doesn't
    /// parse on either side falls back to string equality rather than
    /// claiming a match. Two absent values are equal; an absent and a present
    /// one are not. (Moved here from `AppDatabase+DerivedCounters` so the
    /// placement gate and `isMintedForBoard` share one definition.)
    ///
    /// - Parameters:
    ///   - a: One stored start date (a derived row's).
    ///   - b: The other (its candidate board's).
    /// - Returns: True when both name the same instant (or the same literal).
    static func sameWindowStart(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == b }
        guard let da = DateFormatting.parseISO(a), let db = DateFormatting.parseISO(b) else {
            return a == b
        }
        return da == db
    }

    /// Is `task` a window-stamped derived counter stamped for THIS board's
    /// window — i.e. the row a placement on `board` may point at as-is?
    ///
    /// Only the window START is compared (``sameWindowStart(_:_:)``).
    ///
    /// Mirrors the TS `isWindowStampedForBoard`.
    ///
    /// - Parameters:
    ///   - task: The row about to be placed.
    ///   - board: The board it is being placed on.
    /// - Returns: True when the row is this board's own window-stamped artifact.
    static func isWindowStampedForBoard(_ task: Task, board: Board) -> Bool {
        isWindowStampedDerived(task) && sameWindowStart(task.startDate, board.startDate)
    }
}
