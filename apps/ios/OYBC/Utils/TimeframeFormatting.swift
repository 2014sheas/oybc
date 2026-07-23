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

// MARK: - Board Expiry Helpers

/// Returns whether a board is expired (past its end date).
///
/// Custom and indefinite boards never expire (no deadline) — mirror of the
/// shared `isBoardIndefinite()` exclusion.
///
/// - Parameter board: The board to check.
/// - Returns: `true` if the board has a deadline that is now in the past.
func isBoardExpired(_ board: Board) -> Bool {
    guard board.timeframe != .custom, !board.isIndefinite else { return false }
    guard let endStr = board.endDate, let end = parseISO8601Date(endStr) else { return false }
    return Date() > end
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
