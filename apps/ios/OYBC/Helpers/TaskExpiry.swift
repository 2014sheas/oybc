import Foundation

// MARK: - Phase 6.Y Timeboxed Tasks — Task expiry predicate
//
// Swift twin of `packages/shared/src/algorithms/taskExpiry.ts`
// (`isTaskExpired` / the internal `parseTaskEndDate`). Any change to the
// date-shape handling there MUST be mirrored here — the TS file is the
// source of truth. Extracted from an inline implementation that used to
// live on `TasksTabViewModel` (issue #246 part 2); `TasksTabViewModel`
// now forwards to this helper so existing call sites are unaffected.
enum TaskExpiry {

    /// Returns `true` when the task has an `endDate` AND that date has
    /// passed. "Indefinite" tasks (no `endDate` set, which today implies
    /// also no `timeframe`/`startDate`) are never expired.
    ///
    /// Used by:
    ///   - The Tasks-tab default filter (hides expired tasks unless the
    ///     "Show expired" toggle is on).
    ///   - The wizard's "add from library" picker and "from a board" grid,
    ///     both of which exclude expired tasks from selection.
    ///
    /// Date shapes supported (see `parseTaskEndDate`): `YYYY-MM-DD`
    /// (local end-of-day), local-ISO without timezone (`toLocalISO()`),
    /// and full ISO8601 with `Z` or offset suffix. The Dexie/GRDB backfill
    /// migrations write the same shape the source `Board.endDate` carries,
    /// which is local-ISO today — but the schema is loose enough that the
    /// predicate must remain robust across all three.
    ///
    /// - Parameters:
    ///   - task: Task row with `endDate` (and optional `timeframe`/`startDate`).
    ///   - now: Reference time for the comparison. Defaults to `Date()`;
    ///     injected for deterministic tests.
    /// - Returns: `true` iff the task carries a parseable `endDate` < `now`.
    static func isTaskExpired(_ task: Task, now: Date = Date()) -> Bool {
        guard let endIso = task.endDate else { return false }
        guard let end = parseTaskEndDate(endIso) else { return false }
        return now > end
    }

    /// Parse the supported `Task.endDate` shapes into a `Date`. See
    /// `isTaskExpired` for the full shape contract. Returns `nil` for
    /// unparseable strings; callers treat that as "indefinite".
    static func parseTaskEndDate(_ s: String) -> Date? {
        if let end = parseLocalEndOfDayDate(s) { return end }
        return parseISO8601Date(s)
    }

    /// If `s` is a calendar-only `YYYY-MM-DD` string, return the local
    /// end-of-day Date for that calendar date. Returns nil for any
    /// other shape so the timestamped branch can take over.
    ///
    /// Calendar-only `YYYY-MM-DD` is interpreted as **local end-of-day**
    /// (`23:59:59.999` in the device's local timezone) — distinct from
    /// parsing it as UTC midnight, which would expire the task up to a
    /// day early for users east of UTC.
    private static func parseLocalEndOfDayDate(_ s: String) -> Date? {
        guard s.count == 10 else { return nil }
        let parts = s.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), parts[0].count == 4,
              let month = Int(parts[1]), parts[1].count == 2,
              let day = Int(parts[2]), parts[2].count == 2 else {
            return nil
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 23
        comps.minute = 59
        comps.second = 59
        comps.nanosecond = 999_000_000
        return Calendar.current.date(from: comps)
    }
}
