import Foundation

/// Navigation value for the per-window core-board pager. Carries the
/// timeframe + the seed window start (local ISO). Mirror of `CoreBrowserRoute`.
///
/// iOS twin of the web `CoreWindowRoute` concept — pushed onto the
/// Boards-tab NavigationStack to open a single-window pager centred on
/// a specific calendar window for a given timeframe.
struct CoreWindowRoute: Hashable {
    let timeframe: Timeframe
    /// Local-ISO window start (matches `Board.startDate` for string-equal lookup).
    let windowStart: String
}
