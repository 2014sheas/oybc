import Foundation

// MARK: - Counter Daily Totals (R2 Counters UX refresh)
//
// Swift port of `packages/shared/src/algorithms/counterDailyTotals.ts` —
// derives a counter's trailing daily totals (the Counter Detail 7-day
// sparkline + "Today" stat) from its source task's raw `task_events` stream.
//
// Part of the R2 Counters UX refresh (docs/SHARED_COUNTERS.md §Counters UX
// refresh → "P4 data — UI built now, fed later" — the sparkline and Today
// are fed for REAL here; Streak / Best week / Recent weeks stay stubbed
// pending genuine P4 rollup storage).
//
// Every counter log is a single `TaskEvent{kind:.increment, delta}` row on
// the SOURCE task only (derived/linked tasks are carved out — they own no
// events). So a counter's whole history is one event stream keyed by
// `taskId == sourceTaskId`. Seed/backfill events (P5 hub-born counters'
// starting-count seed) carry the far-past sentinel `occurredAt`
// (`TaskEvents.seedEventOccurredAt`) and are excluded from day-bucketing —
// they represent a one-time starting balance, not an activity occurrence on
// any real day.
//
// Pure and fully deterministic: every notion of "now" flows through the
// `now` parameter, never an ambient `Date()`.

/// A single day's bucketed total.
struct CounterDailyTotal: Equatable {
    /// The bucket's local calendar day, as `YYYY-MM-DD` (device-local
    /// calendar fields — see `localDayKey`). Not a full ISO8601 timestamp;
    /// the `dateISO` name matches the field's role (a date, expressed in
    /// ISO `YYYY-MM-DD` form) without implying a time-of-day component.
    let dateISO: String
    /// Sum of `delta` for increment events whose `occurredAt` falls on this day.
    let total: Int
}

/// Result of `deriveCounterDailyTotals`.
struct CounterDailyTotalsResult: Equatable {
    /// Exactly the requested number of entries, oldest first, today last,
    /// zero-filled for any day with no activity.
    let days: [CounterDailyTotal]
    /// Convenience: `days.last?.total` (today's bucket), 0 when `days` is empty.
    let todayTotal: Int
}

/// Thrown by `deriveCounterDailyTotals` for an invalid `days` window.
struct CounterDailyTotalsError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Local calendar-day key for a timestamp, as `YYYY-MM-DD`.
///
/// Uses `Calendar.current`'s LOCAL date components — the device's local
/// timezone — the same convention the web twin's `localDayKey` uses via the
/// JS `Date` object's local getters. Two events during the same wall-clock
/// day bucket together regardless of what timezone offset their ISO string
/// carries: `DateFormatting.parseISO` resolves to an absolute instant, then
/// this reads it back out in the CALLING device's local time — intentional,
/// so a user always sees "today"/"this week" relative to their own clock.
private func localDayKey(_ date: Date) -> String {
    let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
    let y = comps.year ?? 1970
    let mo = String(format: "%02d", comps.month ?? 1)
    let da = String(format: "%02d", comps.day ?? 1)
    return "\(y)-\(mo)-\(da)"
}

/// Derives a counter's trailing daily totals from its source task's raw
/// increment events.
///
/// Filters to: `taskId == sourceTaskId`, `kind == .increment`, `!isDeleted`,
/// and `occurredAt != seedSentinel`. Pre-amount-logging events (from before
/// R2) carry `delta: ±1` — no special-casing needed, they sum in exactly
/// like any other increment.
///
/// - Parameters:
///   - events: All candidate events (typically the source task's full
///     non-deleted event set, or a superset — filtering is internal).
///   - sourceTaskId: Only events with this `taskId` are counted.
///   - now: ISO8601 "now" — every day boundary is computed relative to this.
///   - days: Window size in trailing days (inclusive of today). Must be a
///     positive integer.
///   - seedSentinel: The seed-event sentinel `occurredAt`
///     (`TaskEvents.seedEventOccurredAt`) — events stamped with this exact
///     value are backfilled starting-count seeds, not real activity, and
///     are excluded from bucketing.
/// - Returns: `{ days, todayTotal }`.
/// - Throws: `CounterDailyTotalsError` if `days` is not positive, or if
///   `now` fails to parse.
func deriveCounterDailyTotals(
    events: [TaskEvent],
    sourceTaskId: String,
    now: String,
    days: Int,
    seedSentinel: String
) throws -> CounterDailyTotalsResult {
    guard days > 0 else {
        throw CounterDailyTotalsError(
            message: "deriveCounterDailyTotals: days must be a positive integer, got \(days)"
        )
    }
    guard let nowDate = DateFormatting.parseISO(now) else {
        throw CounterDailyTotalsError(message: "deriveCounterDailyTotals: could not parse `now`: \(now)")
    }

    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: nowDate)

    // Build the ordered trailing window of day keys — oldest first, today last.
    var dayKeys: [String] = []
    for i in stride(from: days - 1, through: 0, by: -1) {
        let bucketDate = calendar.date(byAdding: .day, value: -i, to: startOfToday) ?? startOfToday
        dayKeys.append(localDayKey(bucketDate))
    }
    let todayKey = dayKeys.last ?? localDayKey(startOfToday)

    var totalsByDay: [String: Int] = Dictionary(uniqueKeysWithValues: dayKeys.map { ($0, 0) })

    for event in events {
        guard event.taskId == sourceTaskId else { continue }
        guard event.kind == .increment else { continue }
        guard !event.isDeleted else { continue }
        guard event.occurredAt != seedSentinel else { continue }
        guard let eventDate = DateFormatting.parseISO(event.occurredAt) else { continue }

        let key = localDayKey(eventDate)
        guard totalsByDay[key] != nil else { continue } // outside the trailing window
        totalsByDay[key, default: 0] += (event.delta ?? 0)
    }

    let daysResult = dayKeys.map { CounterDailyTotal(dateISO: $0, total: totalsByDay[$0] ?? 0) }
    return CounterDailyTotalsResult(days: daysResult, todayTotal: totalsByDay[todayKey] ?? 0)
}
