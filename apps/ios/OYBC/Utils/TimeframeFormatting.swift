import Foundation

// MARK: - Timeframe / board-window formatting utilities
//
// These helpers were previously housed in the (now-removed) Playground's
// `PlaygroundUtils.swift`. They are pure date/timeframe/board-window
// formatting used throughout production (Boards tab, Create wizard,
// recurring-board services) and have nothing to do with the dev playground —
// hence their move here, alongside `TimeframeBoundaries.swift`.

// MARK: - ISO8601 Date Parsing

/// Cached formatters for `parseISO8601Date` to avoid repeated allocations.
private let _isoFractionalFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let _isoBasicFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
private let _localFractionalFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    return f
}()
private let _localBasicFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f
}()

/// Parses an ISO8601 date string with or without fractional seconds.
///
/// Tries fractional seconds first (e.g., `"2026-03-15T00:00:00.000Z"`),
/// then falls back to seconds-only (e.g., `"2026-03-15T00:00:00Z"`), then to
/// timezone-less local ISO strings produced by web's `toLocalISO`.
///
/// - Parameter string: An ISO8601-formatted date string.
/// - Returns: The parsed `Date`, or `nil` if the string is not valid ISO8601.
func parseISO8601Date(_ string: String) -> Date? {
    // Try ISO8601 with timezone + fractional seconds first (e.g., "...000Z")
    if let d = _isoFractionalFormatter.date(from: string) { return d }
    if let d = _isoBasicFormatter.date(from: string) { return d }
    // Fall back to local ISO strings without timezone (from toLocalISO on web)
    if let d = _localFractionalFormatter.date(from: string) { return d }
    return _localBasicFormatter.date(from: string)
}

// MARK: - Timeframe Label Formatting

/// Returns a human-readable label for a timeframe period.
///
/// Mirrors the shared TypeScript `formatTimeframeLabel` in `packages/shared`.
///
/// - Daily (today): `"Today"`
/// - Daily (other): `"Mar 15, 2026"`
/// - Weekly (same month): `"Week of Mar 23 – 29, 2026"`
/// - Weekly (cross-month, same year): `"Week of Mar 30 – Apr 5, 2026"`
/// - Weekly (cross-year): `"Week of Dec 29 – Jan 4"`
/// - Monthly: `"March 2026"`
/// - Yearly: `"2026"`
/// - Custom: `"Custom"`
///
/// - Parameters:
///   - timeframe: The board's timeframe.
///   - startDate: The computed start date for the period.
/// - Returns: A human-readable period label string.
func formatTimeframeLabel(timeframe: Timeframe, startDate: Date) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale.current

    switch timeframe {
    case .daily:
        if cal.isDateInToday(startDate) { return "Today" }
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: startDate)
    case .weekly:
        let endDate = cal.date(byAdding: .day, value: 6, to: startDate) ?? startDate
        let startMonth = cal.component(.month, from: startDate)
        let endMonth = cal.component(.month, from: endDate)
        let startYear = cal.component(.year, from: startDate)
        let endYear = cal.component(.year, from: endDate)
        f.dateFormat = "MMM"
        let startMonthStr = f.string(from: startDate)
        let startDay = cal.component(.day, from: startDate)
        let endDay = cal.component(.day, from: endDate)
        if startMonth == endMonth {
            return "Week of \(startMonthStr) \(startDay) – \(endDay), \(startYear)"
        } else if startYear == endYear {
            let endMonthStr = f.string(from: endDate)
            return "Week of \(startMonthStr) \(startDay) – \(endMonthStr) \(endDay), \(startYear)"
        } else {
            let endMonthStr = f.string(from: endDate)
            return "Week of \(startMonthStr) \(startDay) – \(endMonthStr) \(endDay)"
        }
    case .monthly:
        f.dateFormat = "MMMM yyyy"
        return f.string(from: startDate)
    case .yearly:
        f.dateFormat = "yyyy"
        return f.string(from: startDate)
    case .custom:
        return "Custom"
    case .indefinite:
        return "Ongoing"
    }
}

/// Cadence label for a recurring board template — communicates that
/// the board re-spawns each window rather than describing a single
/// window. Mirror of TS `formatRecurringCadence`.
///
/// Pair with `formatTimeframeLabel(timeframe:startDate:)` (which
/// describes the *first* spawn window) to compose strings like
/// `"Every week · first spawn Week of May 4 – 10, 2026"`. Without this
/// helper the wizard's date-card and preview-row labels were identical
/// for one-off and recurring boards, hiding the recurrence.
func formatRecurringCadence(timeframe: Timeframe) -> String {
    switch timeframe {
    case .daily:   return "Every day"
    case .weekly:  return "Every week"
    case .monthly: return "Every month"
    case .yearly:  return "Every year"
    case .custom:  return "Custom"
    case .indefinite: return "Ongoing"
    }
}

/// Plain capitalized noun for a timeframe ("Daily"/"Weekly"/"Monthly"/
/// "Yearly"/"Custom"/"Ongoing") — distinct from `formatTimeframeLabel`
/// (a specific window's label, e.g. "Today") and `formatRecurringCadence`
/// (the "Every day" cadence phrasing). Added for the core-board setup
/// "Start every <TF> board with 'X'" checkbox copy
/// (docs/POOLS_RECURRING.md §Surfaces item 6, Task Pools + Recurring
/// Boards Rework P5).
///
/// Several call sites already hand-roll this exact 6-case switch
/// privately (`RisoYourStreaksCard.label(_:)`,
/// `PendingCoreBoardsSectionView.label(for:)`,
/// `RisoCoreTimeframeGrid.timeframeLabel`, `EditTaskSheet.timeframeLabel`
/// — the last one also adds a `.none` case). Not consolidated onto this
/// helper here to keep this change scoped to P5; a future cleanup could
/// route them through this one function.
func timeframeNounLabel(_ timeframe: Timeframe) -> String {
    switch timeframe {
    case .daily:      return "Daily"
    case .weekly:     return "Weekly"
    case .monthly:    return "Monthly"
    case .yearly:     return "Yearly"
    case .custom:     return "Custom"
    case .indefinite: return "Ongoing"
    }
}

/// Cadence adverb used in "Repeats <adverb>" copy — the Board-screen manage
/// row ("Repeats daily · from \"Morning Kickstart\"") and the Boards-tab
/// card subtitle ("repeats daily", lowercase). Mirror of the shared TS
/// `formatCadenceAdverb`/`cadenceAdverb` (Task Pools + Recurring Boards
/// Rework, P6 — docs/POOLS_RECURRING.md §Surfaces items 7–8).
///
/// `.custom`/`.indefinite` fall back to `"regularly"` — a defensive-only
/// branch, since the repeat-cadence picker (Daily/Weekly/Monthly/Yearly,
/// `RisoRepeatBoardCTA`) never produces either value.
func formatCadenceAdverb(_ timeframe: Timeframe) -> String {
    switch timeframe {
    case .daily:      return "daily"
    case .weekly:     return "weekly"
    case .monthly:    return "monthly"
    case .yearly:     return "yearly"
    case .custom, .indefinite: return "regularly"
    }
}

// MARK: - Board Expiry Helpers

/// Returns whether a board is expired (past its end date).
///
/// Only INDEFINITE / no-endDate boards never expire. A CUSTOM board with an
/// end date expires at that date like a timed board (it seals there too) —
/// mirror of web `isBoardExpired` in `boardDisplayUtils.ts` (#355 parity).
///
/// - Parameter board: The board to check.
/// - Returns: `true` if the board has a deadline that is now in the past.
func isBoardExpired(_ board: Board) -> Bool {
    guard !board.isIndefinite else { return false }
    guard let endStr = board.endDate, let end = parseISO8601Date(endStr) else { return false }
    return Date() > end
}

/// Boards-list filter-chip predicate (All / Active / Completed / Draft),
/// shared by `BoardListView` and pinned by unit tests — mirror of web
/// `boardMatchesListFilter` in `boardDisplayUtils.ts`.
///
/// - "all" — every board.
/// - "completed" — every board whose run is over: status COMPLETED
///   (greenlog), PLUS ACTIVE boards that are sealed or expired. A
///   sealed-but-incomplete board keeps status ACTIVE forever by design
///   (the F3 sealing rule), so status alone can't classify it. Card badges
///   (CLOSED / Expired / Completed) distinguish how each board finished.
/// - "active" — ACTIVE boards still in play (not sealed, not expired).
/// - anything else ("draft") — exact status match.
///
/// - Parameters:
///   - board: The board to classify.
///   - filter: The selected chip value.
/// - Returns: `true` when the board belongs under the given chip.
func boardMatchesListFilter(_ board: Board, filter: String) -> Bool {
    guard filter != "all" else { return true }
    let ended = board.sealedAt != nil || isBoardExpired(board)
    if filter == BoardStatus.completed.rawValue {
        return board.status == .completed || (board.status == .active && ended)
    }
    guard board.status.rawValue == filter else { return false }
    if filter == BoardStatus.active.rawValue, ended { return false }
    return true
}

/// Returns a human-readable expiry indicator for a board.
///
/// - "No deadline" — Custom or Indefinite board (no end date)
/// - "Expired" — past its end date
/// - "Expires today" — less than 24 hours remaining
/// - "1 day left" / "N days left"
///
/// - Parameter board: The board to evaluate.
/// - Returns: A short expiry label string.
func getExpiryLabel(_ board: Board) -> String {
    // A custom board with an end date expires at that date like a timed board
    // (it seals there too); only INDEFINITE / no-endDate boards read "No deadline".
    guard !board.isIndefinite else { return "No deadline" }
    guard let endStr = board.endDate, let end = parseISO8601Date(endStr) else { return "No deadline" }
    let now = Date()
    guard now <= end else { return "Expired" }
    let secondsLeft = end.timeIntervalSince(now)
    if secondsLeft < 86_400 { return "Expires today" }
    let daysLeft = Int(ceil(secondsLeft / 86_400))
    if daysLeft == 1 { return "1 day left" }
    return "\(daysLeft) days left"
}

// MARK: - Board List Sort

/// Boards-screen ordering — Swift mirror of `@oybc/shared`'s
/// `compareBoardsForList`. Active boards (still in play) first, ordered by
/// soonest endDate (no-deadline boards last), then non-active boards by most
/// recent activity. Ties within a group break by `updatedAt` descending.
/// Keep in lock-step with the TS comparator + its unit tests.
///
/// Written as an `areInIncreasingOrder` predicate for `sorted(by:)`: returns
/// `true` iff `a` should be ordered before `b`.
///
/// - Parameters:
///   - a: First board.
///   - b: Second board.
///   - now: Reference time for the expiry check (injectable for tests).
/// - Returns: `true` if `a` sorts before `b`.
func compareBoardsForList(_ a: Board, _ b: Board, now: Date = Date()) -> Bool {
    let aActive = isActiveForSort(a, now: now)
    let bActive = isActiveForSort(b, now: now)

    // 1. Active group before non-active group.
    if aActive != bActive { return aActive }

    // 2. Both active — soonest deadline first, no-deadline boards last.
    if aActive {
        let aEnd = deadlineTime(a)
        let bEnd = deadlineTime(b)
        if aEnd != bEnd {
            if aEnd == nil { return false } // a has no deadline → after b
            if bEnd == nil { return true }  // b has no deadline → after a
            return aEnd! < bEnd!            // ascending: soonest first
        }
        // Same (or both-missing) deadline → most recent activity first.
        return activityAfter(a, b)
    }

    // 3. Both non-active — most recent activity / completion first.
    return activityAfter(a, b)
}

/// A board "still in play": ACTIVE status, not sealed, not past its endDate.
private func isActiveForSort(_ board: Board, now: Date) -> Bool {
    guard board.status == .active else { return false }
    guard board.sealedAt == nil else { return false }
    return !isBoardExpiredAt(board, now: now)
}

/// `isBoardExpired` with an injectable reference time, for deterministic
/// sort-comparator tests. `isBoardExpired(_:)` itself always reads `Date()`.
private func isBoardExpiredAt(_ board: Board, now: Date) -> Bool {
    guard !board.isIndefinite else { return false }
    guard let endStr = board.endDate, let end = parseISO8601Date(endStr) else { return false }
    return now > end
}

/// The board's deadline as a `Date`, or `nil` for INDEFINITE / no endDate.
private func deadlineTime(_ board: Board) -> Date? {
    guard !board.isIndefinite else { return nil }
    guard let endStr = board.endDate else { return nil }
    return parseISO8601Date(endStr)
}

/// `true` iff `a.updatedAt` is more recent than `b.updatedAt` (descending
/// activity order). Unparseable timestamps fall back to `.distantPast` so a
/// malformed value never crashes the comparator or breaks the strict-weak
/// ordering — mirrors `PlacementIntegrity.swift`'s `updatedAt` handling.
private func activityAfter(_ a: Board, _ b: Board) -> Bool {
    let aTime = parseISO8601Date(a.updatedAt) ?? .distantPast
    let bTime = parseISO8601Date(b.updatedAt) ?? .distantPast
    return aTime > bTime
}
