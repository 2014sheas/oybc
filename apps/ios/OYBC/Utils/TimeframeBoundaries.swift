import Foundation

// MARK: - Timeframe boundary helpers
//
// Top-level Swift equivalents of `getTimeframeBoundaries` /
// `formatTimeframeLabel` / `toLocalISO` in `packages/shared`. Used by
// the board-creation wizard and any other future view that needs to
// compute start/end boundaries for a chosen timeframe.

/// Returns the (start, end) `Date` boundaries for the given timeframe
/// relative to `referenceDate`. Returns `nil` for `.custom`.
///
/// - Parameters:
///   - timeframe: The selected timeframe.
///   - referenceDate: Anchor date (typically `Date()`).
///   - weekStartDay: `"monday"` or `"sunday"` — only used for `.weekly`.
func computeTimeframeBoundaries(
    timeframe: Timeframe,
    referenceDate: Date,
    weekStartDay: String
) -> (start: Date, end: Date)? {
    switch timeframe {
    case .daily:   return computeDayBoundaries(referenceDate)
    case .weekly:  return computeWeekBoundaries(referenceDate, weekStartDay: weekStartDay)
    case .monthly: return computeMonthBoundaries(referenceDate)
    case .yearly:  return computeYearBoundaries(referenceDate)
    case .custom:  return nil
    }
}

/// Start-of-day and end-of-day (23:59:59.999) for `date`.
func computeDayBoundaries(_ date: Date) -> (start: Date, end: Date) {
    var cal = Calendar.current
    cal.timeZone = TimeZone.current
    let start = cal.startOfDay(for: date)
    let end = cal.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-0.001)
    return (start, end)
}

/// Start and end of the week that contains `date`. `weekStartDay`
/// chooses Monday (ISO) vs Sunday anchoring.
func computeWeekBoundaries(_ date: Date, weekStartDay: String) -> (start: Date, end: Date) {
    var cal = Calendar.current
    cal.timeZone = TimeZone.current
    cal.firstWeekday = weekStartDay == "sunday" ? 1 : 2
    let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
    let start = cal.date(from: components)!
    let end = cal.date(byAdding: .day, value: 7, to: start)!.addingTimeInterval(-0.001)
    return (start, end)
}

/// Start of the month and last-millisecond of the month for `date`.
func computeMonthBoundaries(_ date: Date) -> (start: Date, end: Date) {
    var cal = Calendar.current
    cal.timeZone = TimeZone.current
    let components = cal.dateComponents([.year, .month], from: date)
    let start = cal.date(from: components)!
    let end = cal.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-0.001)
    return (start, end)
}

/// Start of the year and last-millisecond of the year for `date`.
func computeYearBoundaries(_ date: Date) -> (start: Date, end: Date) {
    var cal = Calendar.current
    cal.timeZone = TimeZone.current
    let components = cal.dateComponents([.year], from: date)
    let start = cal.date(from: components)!
    let end = cal.date(byAdding: .year, value: 1, to: start)!.addingTimeInterval(-0.001)
    return (start, end)
}

/// Local-ISO string (no timezone suffix) — preserves the user's wall-
/// clock boundary instead of converting to UTC. Mirrors the shared TS
/// `toLocalISO()`.
func wizardLocalISOString(_ date: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar.current
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    return f.string(from: date)
}

/// Calendar-only formatter (`yyyy-MM-dd`) used by the wizard's custom
/// date pickers — matches the web `<input type="date">` value format.
func wizardCalendarISOString(_ date: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar.current
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

/// Parses a `yyyy-MM-dd` string back to a local `Date` at start-of-day.
func parseWizardCalendarDate(_ string: String) -> Date? {
    guard string.count == 10 else { return nil }
    let f = DateFormatter()
    f.calendar = Calendar.current
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: f.date(from: string) ?? Date()) == string
        ? f.date(from: string)
        : nil
}
