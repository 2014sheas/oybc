import Foundation

/// Pro gating — the iOS mirror of the shared TypeScript config
/// `packages/shared/src/constants/proGating.ts`. Keep the two in lock-step (the
/// single cross-platform definition of "what's Pro" + the free-tier caps).
///
/// **Client gates are UX only, never a security boundary** — anything
/// abuse-sensitive re-checks server-side. See docs/MONETIZATION.md.
///
/// Free = one-off boards (≤ `maxActiveBoardsFree`) + normal/counting tasks + full
/// streaks/greenlog/bingo. Pro = unlimited boards + all recurring/core boards +
/// achievement + compound tasks.
enum ProFeature {
    case unlimitedBoards
    /// All recurring/core boards: daily, weekly, monthly, yearly, templates, custom.
    case recurringBoards
    case achievementTasks
    case compoundTasks
}

enum ProGating {
    /// RevenueCat entitlement identifier that grants Pro. Same string both platforms.
    static let entitlementID = "oybc_pro"

    /// Max concurrently-ACTIVE boards on free (sealed / past-window boards excluded).
    static let maxActiveBoardsFree = 5

    /// Grace window after expiry before a user is treated as free — covers store
    /// billing-retry windows and brief offline staleness so a paying user is never
    /// hard-locked on a transient blip.
    static let gracePeriodDays = 3

    private static let graceInterval = TimeInterval(gracePeriodDays * 24 * 60 * 60)

    /// Whether an entitlement grants **active** Pro access at `now`, applying the
    /// grace window. Authoritative client-side "is Pro" check — prefer over the
    /// denormalized `entitlement.isPro`.
    ///
    /// free → false · lifetime (nil `expiresAt`) → true · subscription → active
    /// until `expiresAt` + grace · unparseable expiry on a pro doc → true (fail
    /// OPEN: never hard-lock a payer over a malformed timestamp).
    static func isEntitlementActive(_ entitlement: Entitlement, now: Date) -> Bool {
        guard entitlement.tier == .pro else { return false }
        guard let expiresAt = entitlement.expiresAt else { return true } // lifetime / non-expiring
        guard let expiry = parseISO8601(expiresAt) else { return true } // fail open
        return now <= expiry.addingTimeInterval(graceInterval)
    }

    /// Convenience alias for the active-Pro check used across gates.
    static func isPro(_ entitlement: Entitlement, now: Date) -> Bool {
        isEntitlementActive(entitlement, now: now)
    }

    /// Whether a boolean Pro feature is locked. Use for `recurringBoards`,
    /// `achievementTasks`, `compoundTasks`. (`unlimitedBoards` is a count cap — use
    /// `isOverFreeLimit`.) Locked iff the user is not active-Pro.
    static func isFeatureGated(_ feature: ProFeature, _ entitlement: Entitlement, now: Date) -> Bool {
        !isPro(entitlement, now: now)
    }

    /// Whether creating one more count-limited resource would exceed the free cap.
    /// Pro is never over a limit. Today only `unlimitedBoards` is count-based;
    /// `currentCount` is the user's current ACTIVE (non-sealed, non-deleted) boards.
    static func isOverFreeLimit(
        _ feature: ProFeature,
        currentCount: Int,
        _ entitlement: Entitlement,
        now: Date
    ) -> Bool {
        if isPro(entitlement, now: now) { return false }
        switch feature {
        case .unlimitedBoards:
            return currentCount >= maxActiveBoardsFree
        default:
            return false
        }
    }

    /// Board-creation gate: can a user with `activeBoardCount` active boards create
    /// another? Pro → always; free → under the cap.
    static func canCreateBoard(activeBoardCount: Int, _ entitlement: Entitlement, now: Date) -> Bool {
        !isOverFreeLimit(.unlimitedBoards, currentCount: activeBoardCount, entitlement, now: now)
    }

    /// Parses an ISO8601 timestamp, tolerating both fractional-seconds
    /// ("…:00.000Z", what the webhook/JS `toISOString()` emit) and plain
    /// ("…:00Z") forms.
    private static func parseISO8601(_ value: String) -> Date? {
        if let d = iso8601Fractional.date(from: value) { return d }
        return iso8601Plain.date(from: value)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
