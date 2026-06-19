import Foundation

// MARK: - Notification Planner — Phase 7 (iOS local reminders)
//
// Pure function over the local `boards` table + `UserPreferences` that
// computes the FULL desired set of local notifications the app should have
// scheduled with the OS at a given moment. It has NO `UserNotifications`
// dependency — it returns plain value types so it is fully unit-testable with
// an injected `now` (mirrors the `RecurringBoards.swift` pure-function
// convention).
//
// `NotificationService` consumes this, maps each `PlannedNotification` to a
// `UNNotificationRequest`, and reconciles (diff add/remove) against the OS's
// pending set. Identifiers are deterministic so re-running the plan is an
// idempotent set-diff, never a duplicate.
//
// Design invariants (see docs/NOTIFICATIONS.md):
//   • No background execution — these are scheduled while foregrounded; the OS
//     delivers them later. Nothing here writes to the DB.
//   • The 64-pending-per-app OS cap is respected DETERMINISTICALLY here, in the
//     planner, never delegated to iOS's opaque "soonest 64" truncation.
//   • Copy stays strictly functional (App Store guideline 4.5.4) — no
//     marketing / re-engagement language.
//
// Canonical doc: docs/NOTIFICATIONS.md.

// MARK: - PlannedNotification

/// One notification the app wants scheduled. Value type; `Equatable` so tests
/// can assert exact plans and the service can diff cheaply.
struct PlannedNotification: Equatable {

    /// Notification kind. The raw value prefixes the identifier so the service
    /// can reason about categories when diffing.
    enum Category: String {
        case expiry
        case recurringWindow
        case dailyReminder
    }

    /// How the OS should fire this notification.
    enum Trigger: Equatable {
        /// One-shot at an absolute future instant (expiry / window-open).
        case calendar(date: Date)
        /// Repeating daily at a wall-clock time (the daily play reminder).
        case dailyTime(hour: Int, minute: Int)
    }

    /// Stable, deterministic identifier — drives the idempotent reconcile diff.
    let identifier: String
    let category: Category
    let title: String
    let body: String
    let trigger: Trigger
    /// Carried into `UNNotificationRequest.content.userInfo` for deep-linking
    /// on tap (e.g. `["boardId": …]`). Empty when there's no target.
    let userInfo: [String: String]
}

// MARK: - Planner

enum NotificationPlanner {

    // MARK: Tuning constants

    /// Wall-clock hour (local) at which the one-shot expiry-eve and
    /// window-open notifications fire. 9am avoids the poor UX of a midnight
    /// fire at the raw window/endDate boundary.
    static let notificationHour = 9

    /// Expiry notifications further than this many days out are not scheduled
    /// yet — they get armed on a later reconcile once they enter the horizon.
    /// The dominant lever for staying under the OS cap with many boards.
    static let expiryHorizonDays = 30

    /// Per-category budget so the total desired set is deterministically below
    /// the ~64 OS cap (expiry 50 + recurring-window ≤3 + daily 1 = ≤54).
    /// Expiry candidates beyond this are dropped soonest-first.
    static let expiryBudget = 50

    /// Recurring-window notifications fire only for these timeframes. DAILY is
    /// intentionally excluded: a daily window opens every midnight, which would
    /// be both noisy and badly-timed — the daily play reminder covers a daily
    /// cadence at a user-chosen hour instead.
    private static let recurringWindowTimeframes: [Timeframe] = [.weekly, .monthly, .yearly]

    // MARK: Entry point

    /// Computes the full desired notification set from local state.
    ///
    /// Returns `[]` when the master `notificationsEnabled` pref is off. The
    /// service additionally short-circuits to `[]` when the OS permission is
    /// not granted — the planner is permission-agnostic by design.
    ///
    /// - Parameters:
    ///   - boards: All boards for the active user (caller scopes by userId).
    ///   - prefs: The user's preferences.
    ///   - now: Reference instant (injected for determinism / testing).
    static func desiredNotifications(
        boards: [Board],
        prefs: UserPreferences,
        now: Date
    ) -> [PlannedNotification] {
        guard prefs.notificationsEnabled else { return [] }

        var result: [PlannedNotification] = []
        result.append(contentsOf: expiryNotifications(boards: boards, prefs: prefs, now: now))
        result.append(contentsOf: recurringWindowNotifications(boards: boards, prefs: prefs, now: now))
        if let daily = dailyReminderNotification(prefs: prefs) {
            result.append(daily)
        }
        return result
    }

    // MARK: Board expiring soon

    /// One `expiry-<boardId>` per active, non-daily board whose deadline is
    /// inside the horizon, fired at 9am the day before the deadline. Capped at
    /// `expiryBudget`, soonest-first (tie-break by board id for stability).
    private static func expiryNotifications(
        boards: [Board],
        prefs: UserPreferences,
        now: Date
    ) -> [PlannedNotification] {
        guard prefs.expiringReminders else { return [] }

        let cal = Calendar.current
        let horizonEnd = cal.date(byAdding: .day, value: expiryHorizonDays, to: now) ?? now

        // (fireDate, board) pairs so we can sort + budget deterministically.
        var candidates: [(fireDate: Date, board: Board)] = []
        for board in boards {
            guard !board.isDeleted, board.status == .active else { continue }
            // Skip daily — "the day before" ≈ creation time, which is noise.
            guard board.timeframe != .daily else { continue }
            guard let end = parseISO8601Date(board.endDate) else { continue }
            guard let fireDate = expiryEveFireDate(endDate: end, calendar: cal) else { continue }
            guard fireDate > now, fireDate <= horizonEnd else { continue }
            candidates.append((fireDate, board))
        }

        // Soonest-first; ties broken by board id so truncation is stable
        // across reconciles regardless of the input order.
        candidates.sort {
            $0.fireDate != $1.fireDate
                ? $0.fireDate < $1.fireDate
                : $0.board.id < $1.board.id
        }

        return candidates.prefix(expiryBudget).map { candidate in
            let board = candidate.board
            return PlannedNotification(
                identifier: "expiry-\(board.id)",
                category: .expiry,
                title: "Board expiring soon",
                body: "“\(board.name)” expires tomorrow.",
                trigger: .calendar(date: candidate.fireDate),
                userInfo: ["boardId": board.id]
            )
        }
    }

    /// 9am on the calendar day before `endDate`'s day. Returns `nil` only if
    /// the calendar math fails (it shouldn't for valid dates).
    private static func expiryEveFireDate(endDate: Date, calendar cal: Calendar) -> Date? {
        let endDay = cal.startOfDay(for: endDate)
        guard let dayBefore = cal.date(byAdding: .day, value: -1, to: endDay) else { return nil }
        return cal.date(bySettingHour: notificationHour, minute: 0, second: 0, of: dayBefore)
    }

    // MARK: New recurring window

    /// One `recurring-window-<timeframe>-<nextStartISO>` per enabled
    /// weekly/monthly/yearly timeframe whose NEXT window has no core board yet,
    /// fired at 9am on that window's first day. There are at most three, so no
    /// horizon/budget is needed (they don't pressure the OS cap).
    private static func recurringWindowNotifications(
        boards: [Board],
        prefs: UserPreferences,
        now: Date
    ) -> [PlannedNotification] {
        guard prefs.recurringWindowReminders else { return [] }

        let cal = Calendar.current
        var result: [PlannedNotification] = []

        for timeframe in recurringWindowTimeframes {
            guard isRecurringTimeframeEnabled(prefs, timeframe) else { continue }
            guard let current = computeTimeframeBoundaries(
                timeframe: timeframe,
                referenceDate: now,
                weekStartDay: prefs.weekStartDay.rawValue
            ) else { continue }
            guard let next = stepCoreBoardWindow(
                timeframe: timeframe,
                fromStartIso: wizardLocalISOString(current.start),
                step: 1,
                weekStartDay: prefs.weekStartDay.rawValue
            ) else { continue }

            let nextStartISO = wizardLocalISOString(next.start)

            // Suppress if a core board already exists for the next window
            // (e.g. the user created it ahead via the window pager). Mirrors
            // the `findPendingRecurringBoards` match condition.
            let alreadyExists = boards.contains { board in
                board.timeframe == timeframe
                    && !board.isDeleted
                    && board.startDate == nextStartISO
                    && board.isCore
            }
            if alreadyExists { continue }

            let firstDay = cal.startOfDay(for: next.start)
            guard let fireDate = cal.date(
                bySettingHour: notificationHour, minute: 0, second: 0, of: firstDay
            ), fireDate > now else { continue }

            result.append(PlannedNotification(
                identifier: "recurring-window-\(timeframe.rawValue)-\(nextStartISO)",
                category: .recurringWindow,
                title: "New \(timeframe.rawValue) board",
                body: "A new \(formatRecurringCadence(timeframe: timeframe).lowercased()) window is open — set up your board.",
                trigger: .calendar(date: fireDate),
                userInfo: ["timeframe": timeframe.rawValue]
            ))
        }

        return result
    }

    // MARK: Daily play reminder

    /// The single repeating `daily-play-reminder`, fired at the user's chosen
    /// `dailyPlayReminderTime`. Independent of board state.
    private static func dailyReminderNotification(prefs: UserPreferences) -> PlannedNotification? {
        guard prefs.dailyPlayReminderEnabled else { return nil }
        guard let (hour, minute) = parseReminderTime(prefs.dailyPlayReminderTime) else { return nil }
        return PlannedNotification(
            identifier: "daily-play-reminder",
            category: .dailyReminder,
            title: "Time to play",
            body: "Open your boards and make progress today.",
            trigger: .dailyTime(hour: hour, minute: minute),
            userInfo: [:]
        )
    }

    /// Parses a validated "HH:mm" string into `(hour, minute)`. Returns `nil`
    /// for a malformed value (defensive — prefs are validated on decode).
    static func parseReminderTime(_ value: String) -> (hour: Int, minute: Int)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        // Require 2-digit "HH:mm" — matches `UserPreferences.isValidReminderTime`
        // so the planner and the pref validator agree on what's well-formed.
        guard parts.count == 2,
              parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    // MARK: Helpers

    /// Whether the per-timeframe `recurring${T}Enabled` flag is set. (Local
    /// copy of the `RecurringBoards.swift` private helper — kept here so the
    /// planner has no cross-file private dependency.)
    private static func isRecurringTimeframeEnabled(
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
}
