import Foundation

// MARK: - Recurring boards — Phase 6.1 (Timeframe-Prompted)
//
// Pure functions over the local `boards` table + `UserPreferences` that:
//   1. Detect which recurring board windows are pending (no board exists for
//      the current daily/weekly/monthly/yearly window with the corresponding
//      pref enabled). Surfaced via the Boards-tab banner.
//   2. Find currently-active longer-window "parent" boards for a given child
//      timeframe. Used by the wizard's "From parent boards" filter.
//
// Mirrors `packages/shared/src/algorithms/recurringBoards.ts`. No persistence,
// no platform-specific code beyond Foundation. Both functions recompute from
// scratch on each call — caller (view-model) is responsible for re-invoking
// them when boards or prefs change.
//
// Canonical design: docs/ARCHITECTURE.md §Phase 6.

/// Hierarchy of which timeframes "contain" which other timeframes for the
/// purpose of parent-child task derivation. A daily board's parents are the
/// currently-active weekly/monthly/yearly boards; a yearly board has none.
///
/// `.custom` is intentionally empty for Phase 1 — custom boards have user-
/// specified dates rather than computed boundaries, so they don't fit the
/// recurrence machinery.
// Module-level `let` to mirror the TS-side `const PARENT_TIMEFRAMES`
// — pure constant, never mutated.
let parentTimeframesByChild: [Timeframe: [Timeframe]] = [
    .daily:   [.weekly, .monthly, .yearly],
    .weekly:  [.monthly, .yearly],
    .monthly: [.yearly],
    .yearly:  [],
    .custom:  [],
]

/// The four recurring timeframes Phase 1 supports, in **longest-window-first
/// order** so banner consumers can render directly without re-sorting. The
/// order is load-bearing: creating parents before children means the wizard's
/// "From parent boards" filter has something to surface for the daily board.
private let recurringTimeframesByWindowDesc: [Timeframe] = [
    .yearly, .monthly, .weekly, .daily,
]

/// Same set, inverted — used by `getCoreBoardSlots` so the persistent
/// Core Boards section on the home screen reads top-to-bottom as
/// daily → weekly → monthly → yearly. Shortest-first is what the user
/// acts on most often, so it sits at the top.
private let recurringTimeframesByWindowAsc: [Timeframe] = [
    .daily, .weekly, .monthly, .yearly,
]

/// One row of the Boards-tab "pending boards" banner. Carries everything the
/// banner needs to render the row + everything the wizard needs to be
/// prefilled when the user taps "Create".
struct PendingRecurringBoard: Equatable {
    let timeframe: Timeframe
    /// Local ISO8601 string, bit-for-bit comparable against `Board.startDate`.
    let startDate: String
    /// Local ISO8601 string.
    let endDate: String
    /// Human-readable label from `playgroundTimeframeLabel` — e.g. "Today",
    /// "Week of May 4 – 10, 2026", "May 2026", "2026".
    let suggestedName: String
}

/// Returns whether a `UserPreferences`'s `recurring${T}Enabled` flag is true.
/// Returns false for `.custom` — custom is excluded from Phase 1 recurrence.
private func isRecurringTimeframeEnabled(
    _ prefs: UserPreferences,
    _ timeframe: Timeframe
) -> Bool {
    switch timeframe {
    case .daily:   return prefs.recurringDailyEnabled
    case .weekly:  return prefs.recurringWeeklyEnabled
    case .monthly: return prefs.recurringMonthlyEnabled
    case .yearly:  return prefs.recurringYearlyEnabled
    case .custom:  return false
    }
}

/// Finds the recurring-board windows the user should be prompted to create.
///
/// Returns one `PendingRecurringBoard` for every enabled timeframe whose
/// current window has **no** corresponding non-deleted `Board`. Output is
/// **longest-window-first** (yearly → monthly → weekly → daily) so the
/// banner renders parents above children.
///
/// Match condition: `b.timeframe == T` AND `!b.isDeleted` AND
/// `b.startDate == wizardLocalISOString(currentWindowStart)`. String equality
/// is safe because both sides come from the same `wizardLocalISOString`
/// formatter — bit-for-bit identical for the same calendar window.
///
/// - Parameters:
///   - boards: All boards belonging to the active user (caller filters by userId).
///   - prefs: User preferences. `weekStartDay` controls weekly boundaries.
///   - now: Reference date for window computation (typically `Date()`).
func findPendingRecurringBoards(
    boards: [Board],
    prefs: UserPreferences,
    now: Date
) -> [PendingRecurringBoard] {
    var pending: [PendingRecurringBoard] = []

    for timeframe in recurringTimeframesByWindowDesc {
        guard isRecurringTimeframeEnabled(prefs, timeframe) else { continue }
        guard let window = computeTimeframeBoundaries(
            timeframe: timeframe,
            referenceDate: now,
            weekStartDay: prefs.weekStartDay.rawValue
        ) else { continue } // .custom → no boundaries (already filtered above, defensive)

        let startISO = wizardLocalISOString(window.start)
        let endISO = wizardLocalISOString(window.end)

        // Only a *core* board for the window dismisses the banner. Manual
        // ad-hoc boards (same timeframe + same window, isCore = false) are
        // unrelated to the recurring suggestion and must NOT silently
        // suppress it. Core = banner-spawned (Phase 6.1) or template-
        // spawned (Phase 6.2). See `Board.isCore`.
        let alreadyExists = boards.contains { board in
            board.timeframe == timeframe
                && !board.isDeleted
                && board.startDate == startISO
                && board.isCore
        }
        if alreadyExists { continue }

        pending.append(PendingRecurringBoard(
            timeframe: timeframe,
            startDate: startISO,
            endDate: endISO,
            suggestedName: playgroundTimeframeLabel(
                timeframe: timeframe,
                startDate: window.start
            )
        ))
    }

    return pending
}

/// Persistent home-screen "Core Boards" section data — returns one
/// entry per *enabled* recurring timeframe, in shortest-window-first
/// order (daily → weekly → monthly → yearly), with the matched core
/// board attached when one exists for the current window.
///
/// Distinct from `findPendingRecurringBoards`: that helper only
/// returns timeframes that NEED creation. This one always returns
/// every enabled timeframe, with `currentBoard == nil` indicating
/// the not-yet state. The Boards-tab section uses this so the
/// per-timeframe Core Board Browser is always reachable from the
/// home screen, not just when something needs creating.
///
/// Mirrors `getCoreBoardSlots` in `packages/shared/src/algorithms/recurringBoards.ts`.
struct CoreBoardSlot: Identifiable {
    let timeframe: Timeframe
    /// Local ISO8601 string from `wizardLocalISOString`.
    let windowStart: String
    /// Local ISO8601 string.
    let windowEnd: String
    /// Human-readable label (e.g. "Today", "Week of May 4 – 10, 2026").
    let windowLabel: String
    /// The matched core board for the current window, or nil if none.
    let currentBoard: Board?

    /// `Identifiable` conformance — timeframe is unique per slot.
    var id: String { timeframe.rawValue }
}

func getCoreBoardSlots(
    boards: [Board],
    prefs: UserPreferences,
    now: Date
) -> [CoreBoardSlot] {
    var slots: [CoreBoardSlot] = []

    for timeframe in recurringTimeframesByWindowAsc {
        guard isRecurringTimeframeEnabled(prefs, timeframe) else { continue }
        guard let window = computeTimeframeBoundaries(
            timeframe: timeframe,
            referenceDate: now,
            weekStartDay: prefs.weekStartDay.rawValue
        ) else { continue }

        let startISO = wizardLocalISOString(window.start)
        let endISO = wizardLocalISOString(window.end)

        let match = boards.first { board in
            board.timeframe == timeframe
                && !board.isDeleted
                && board.startDate == startISO
                && board.isCore
        }

        slots.append(CoreBoardSlot(
            timeframe: timeframe,
            windowStart: startISO,
            windowEnd: endISO,
            windowLabel: playgroundTimeframeLabel(
                timeframe: timeframe,
                startDate: window.start
            ),
            currentBoard: match
        ))
    }

    return slots
}

/// Returns the currently-active longer-window "parent" boards for a given
/// child timeframe. Used by the wizard's "From parent boards" filter to
/// surface candidate tasks the user can place on the new child board.
///
/// "Currently-active" means: status is `.active`, not deleted, and `now` falls
/// within the board's `[startDate, endDate]` window. A board whose timeframe
/// matches but whose window has expired (e.g. last month's monthly when the
/// caller is creating today's daily) is excluded — it's not a useful source
/// of tasks for the new child.
///
/// Returns an empty array for `.yearly` (no parents) and for `.custom`
/// (excluded from Phase 1 recurrence). The wizard's empty-state UI handles
/// the empty result.
///
/// - Parameters:
///   - childTimeframe: The timeframe of the board being created.
///   - allActiveBoards: Boards to filter. Caller scopes by userId.
///   - now: Reference date for the "currently active" check.
func getParentBoards(
    childTimeframe: Timeframe,
    allActiveBoards: [Board],
    now: Date
) -> [Board] {
    let parentTimeframes = parentTimeframesByChild[childTimeframe] ?? []
    if parentTimeframes.isEmpty { return [] }
    let parentSet = Set(parentTimeframes)

    // Format `now` to a local ISO string once and compare lexicographically
    // against the stored `startDate`/`endDate` strings. Both sides come from
    // the same `wizardLocalISOString` formatter (year-first
    // `yyyy-MM-dd'T'HH:mm:ss.SSS`), so string ordering is identical to date
    // ordering — no need to allocate a DateFormatter and parse 2 dates per
    // board. Saves ~1 alloc + 2 parses per candidate.
    //
    // INVARIANT: every code path that writes `Board.startDate` / `endDate`
    // MUST use the 23-char no-Z `yyyy-MM-dd'T'HH:mm:ss.SSS` format. iOS
    // writers go through `wizardLocalISOString` (Utils/TimeframeBoundaries
    // .swift) and web writers through `toLocalISO` (packages/shared/src/
    // algorithms/calendarBoundaries.ts) which produce identical output.
    // A trailing-Z ISO string (e.g. from `Date().toISOString()`) would
    // sort *after* `T..S.SSS` and silently exclude the board from this
    // result. If a future writer breaks this invariant, the comparison
    // here breaks silently — there is no compile-time or runtime check.
    let nowISO = wizardLocalISOString(now)

    return allActiveBoards.filter { board in
        guard parentSet.contains(board.timeframe) else { return false }
        guard !board.isDeleted else { return false }
        guard board.status == .active else { return false }
        return board.startDate <= nowISO && nowISO <= board.endDate
    }
}
