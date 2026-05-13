import Foundation

// MARK: - Shared Playground Utilities

/// The user ID used consistently across all Playground features.
let playgroundUserId = "playground-user-1"

/// Number of seconds a success message is shown before it auto-dismisses.
let successDismissSeconds: Double = 3.0

private let _playgroundISOFormatter = ISO8601DateFormatter()
private let _playgroundDisplayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

/// Formats an ISO8601 string into a medium-style date with time for display.
///
/// Shared by all Playground structs that need to display task creation dates.
///
/// - Parameter iso: An ISO8601 date string.
/// - Returns: A human-readable date string with time, or the original string if parsing fails.
func formatPlaygroundDate(_ iso: String) -> String {
    guard let date = _playgroundISOFormatter.date(from: iso) else { return iso }
    return _playgroundDisplayFormatter.string(from: date)
}

/// Generates placeholder task names for demo and test sections.
///
/// - Parameter count: Number of task names to generate.
/// - Returns: Array of strings in the format ["Task 1", "Task 2", ...].
func generateTaskNames(count: Int) -> [String] {
    (1...max(1, count)).map { "Task \($0)" }
}

/// Returns a fixed list of realistic sample task titles for seeding the Board Generator.
///
/// - Returns: Array of 10 sample task title strings.
func generateSampleTaskTitles() -> [String] {
    [
        "Morning workout",
        "Read for 30 minutes",
        "Cook a meal at home",
        "Call a friend or family member",
        "Go for a walk outside",
        "Meditate for 10 minutes",
        "Try a new recipe",
        "Clean and tidy a room",
        "Write in a journal",
        "Learn something new",
    ]
}

// MARK: - ISO8601 Date Parsing

/// Parses an ISO8601 date string with or without fractional seconds.
///
/// Tries fractional seconds first (e.g., `"2026-03-15T00:00:00.000Z"`),
/// then falls back to seconds-only (e.g., `"2026-03-15T00:00:00Z"`).
///
/// - Parameter string: An ISO8601-formatted date string.
/// - Returns: The parsed `Date`, or `nil` if the string is not valid ISO8601.
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
func playgroundTimeframeLabel(timeframe: Timeframe, startDate: Date) -> String {
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
    }
}

/// Cadence label for a recurring board template — communicates that
/// the board re-spawns each window rather than describing a single
/// window. Mirror of TS `formatRecurringCadence`.
///
/// Pair with `playgroundTimeframeLabel(timeframe:startDate:)` (which
/// describes the *first* spawn window) to compose strings like
/// `"Every week · first spawn Week of May 4 – 10, 2026"`. Without this
/// helper the wizard's date-card and preview-row labels were identical
/// for one-off and recurring boards, hiding the recurrence.
func recurringCadenceLabel(timeframe: Timeframe) -> String {
    switch timeframe {
    case .daily:   return "Every day"
    case .weekly:  return "Every week"
    case .monthly: return "Every month"
    case .yearly:  return "Every year"
    case .custom:  return "Custom"
    }
}

// MARK: - Board Expiry Helpers

/// Returns whether a board is expired (past its end date and not Custom timeframe).
///
/// - Parameter board: The board to check.
/// - Returns: `true` if the board's timeframe is not `.custom` and its `endDate` is in the past.
func isBoardExpired(_ board: Board) -> Bool {
    guard board.timeframe != .custom else { return false }
    guard let end = parseISO8601Date(board.endDate) else { return false }
    return Date() > end
}

/// Returns a human-readable expiry indicator for a board.
///
/// - "No deadline" — Custom timeframe
/// - "Expired" — past its end date
/// - "Expires today" — less than 24 hours remaining
/// - "1 day left" / "N days left"
///
/// - Parameter board: The board to evaluate.
/// - Returns: A short expiry label string.
func getExpiryLabel(_ board: Board) -> String {
    guard board.timeframe != .custom else { return "No deadline" }
    guard let end = parseISO8601Date(board.endDate) else { return "No deadline" }
    let now = Date()
    guard now <= end else { return "Expired" }
    let secondsLeft = end.timeIntervalSince(now)
    if secondsLeft < 86_400 { return "Expires today" }
    let daysLeft = Int(ceil(secondsLeft / 86_400))
    if daysLeft == 1 { return "1 day left" }
    return "\(daysLeft) days left"
}

// MARK: - Playground User

/// Ensures the shared playground user record exists in the local database.
///
/// Creates the user with a fixed ID and email if it has not been inserted yet.
/// Safe to call multiple times — idempotent.
///
/// Any database errors are silently swallowed; they are non-fatal for Playground use.
func ensurePlaygroundUser() {
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            if try AppDatabase.shared.fetchUser(id: playgroundUserId) == nil {
                let user = User(
                    id: playgroundUserId,
                    email: "playground@oybc.local",
                    displayName: "Playground User",
                    photoURL: nil,
                    createdAt: AppDatabase.currentTimestamp(),
                    updatedAt: AppDatabase.currentTimestamp(),
                    lastSyncedAt: nil,
                    version: 1
                )
                try AppDatabase.shared.saveUser(user)
            }
        } catch {
            // Non-fatal in Playground context
        }
    }
}
