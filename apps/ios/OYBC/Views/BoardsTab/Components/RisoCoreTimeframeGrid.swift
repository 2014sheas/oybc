import SwiftUI

/// 2×2 grid of core timeframe cards shown at the top of the Boards home screen.
///
/// Always shows all four timeframes (Daily / Weekly / Monthly / Yearly) regardless
/// of which recurring preferences are enabled, so the section is a stable anchor
/// for navigation. Each card shows an uppercase label, a status word, and an 8px
/// status dot.
///
/// Status derivation per card:
/// - No core board for the current window → "Ready" (paper/empty dot)
/// - Core board active + expiring soon → "Expiring" (gold dot)
/// - Core board active, not expiring → "Active" (green dot)
/// - Core board completed → "Done" (green dot)
///
/// Tap on any card fires `onSelect(timeframe, windowStart)` where `windowStart`
/// is the current window's ISO8601 start string.
struct RisoCoreTimeframeGrid: View {

    /// The slots to render. Callers should pass one slot per timeframe
    /// (daily, weekly, monthly, yearly). If a timeframe has no slot entry
    /// this view falls back to computing boundaries itself using `now`.
    let slots: [CoreBoardSlot]

    /// Current date used to fill in missing slots and compute expiry.
    var now: Date = Date()

    /// User's week-start preference ("monday"/"sunday"), used only for the
    /// local window-boundary fallback when a weekly slot isn't loaded — keeps
    /// the Weekly card's window in sync with the rest of the app.
    var weekStartDay: String = "monday"

    /// Per-timeframe streaks. Each card shows a small flame badge for its
    /// greenlog streak when ≥ 1. Defaults empty (no badges) so existing
    /// call sites / previews render unchanged.
    var streaks: [Timeframe: StreakPair] = [:]

    /// Fired when the user taps a card. Receives the timeframe and the
    /// ISO8601 local window-start string for that card.
    var onSelect: ((Timeframe, String) -> Void)?

    // All four canonical timeframes, in the display order matching the
    // screenshot: Daily, Weekly, Monthly, Yearly (row-major left-to-right).
    private let displayOrder: [Timeframe] = [.daily, .weekly, .monthly, .yearly]

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ],
            spacing: 8
        ) {
            ForEach(displayOrder, id: \.self) { timeframe in
                let slot = slots.first(where: { $0.timeframe == timeframe })
                CoreTimeframeCard(
                    timeframe: timeframe,
                    slot: slot,
                    now: now,
                    weekStartDay: weekStartDay,
                    greenlogStreak: streaks[timeframe]?.greenlog ?? 0,
                    onTap: { windowStart in
                        onSelect?(timeframe, windowStart)
                    }
                )
            }
        }
    }
}

// MARK: - CoreTimeframeCard

/// Individual card in the 2×2 core timeframe grid.
private struct CoreTimeframeCard: View {

    let timeframe: Timeframe
    let slot: CoreBoardSlot?
    let now: Date
    let weekStartDay: String
    /// Current greenlog streak for this timeframe; a flame badge shows when ≥ 1.
    var greenlogStreak: Int = 0
    let onTap: (String) -> Void

    private var windowStart: String {
        if let slot { return slot.windowStart }
        // Fallback: compute boundaries locally so the card still has a
        // valid windowStart even if the slot was not loaded yet. Respect the
        // user's week-start pref so the Weekly window matches the rest of the app.
        guard let window = computeTimeframeBoundaries(
            timeframe: timeframe,
            referenceDate: now,
            weekStartDay: weekStartDay
        ) else { return "" }
        return wizardLocalISOString(window.start)
    }

    private enum Status {
        case ready, active, expiring, done
        var label: String {
            switch self {
            case .ready:    return "Ready"
            case .active:   return "Active"
            case .expiring: return "Expiring"
            case .done:     return "Done"
            }
        }
        var dotColor: Color {
            switch self {
            case .ready:    return .risoPaper
            case .active:   return .risoGreen
            case .expiring: return .risoGold
            case .done:     return .risoGreen
            }
        }
    }

    private var status: Status {
        guard let board = slot?.currentBoard else { return .ready }
        switch board.status {
        case .completed: return .done
        case .active:
            // "Expiring" = the board's end date is within the next 24 hours.
            // Already-past end dates (negative hoursLeft) are NOT expiring —
            // a current-window core board shouldn't be expired, but guard it
            // so past-window boards read as Active rather than Expiring.
            if let end = parseISO8601Date(board.endDate) {
                let hoursLeft = end.timeIntervalSince(now) / 3600
                return (hoursLeft >= 0 && hoursLeft < 24) ? .expiring : .active
            }
            return .active
        default:
            return .ready
        }
    }

    private var timeframeLabel: String {
        switch timeframe {
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        case .custom:  return "Custom"
        }
    }

    /// Gold flame capsule, e.g. 🔥 3d — the current greenlog streak. Uses
    /// `risoInkStatic` (non-inverting) so it stays readable on gold in dark mode.
    private var streakBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "flame.fill")
                .font(.system(size: 8, weight: .bold))
            Text(compactStreakLabel(greenlogStreak, timeframe: timeframe))
                .font(.risoHead(10, .bold))
        }
        .foregroundStyle(Color.risoInkStatic)
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(Capsule().fill(Color.risoGold))
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: 1.5))
        .accessibilityLabel("\(greenlogStreak) \(timeframeLabel.lowercased()) greenlog streak")
    }

    var body: some View {
        Button {
            onTap(windowStart)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(timeframeLabel)
                        .risoSectionLabel()
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if greenlogStreak >= 1 {
                        streakBadge
                    }
                }

                HStack(spacing: 5) {
                    // 8px status dot with 1.5px keyline
                    Circle()
                        .fill(status.dotColor)
                        .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: 1.5))
                        .frame(width: 8, height: 8)

                    Text(status.label)
                        .font(.risoHead(13, .extraBold))
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                }
                .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .risoCard()
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Core Timeframe Grid — no boards") {
    // All slots have no current board → all show "Ready"
    let slots: [CoreBoardSlot] = [
        CoreBoardSlot(timeframe: .daily, windowStart: "2026-06-12T00:00:00.000", windowEnd: "2026-06-12T23:59:59.999", windowLabel: "Today", currentBoard: nil),
        CoreBoardSlot(timeframe: .weekly, windowStart: "2026-06-09T00:00:00.000", windowEnd: "2026-06-15T23:59:59.999", windowLabel: "This week", currentBoard: nil),
        CoreBoardSlot(timeframe: .monthly, windowStart: "2026-06-01T00:00:00.000", windowEnd: "2026-06-30T23:59:59.999", windowLabel: "June 2026", currentBoard: nil),
        CoreBoardSlot(timeframe: .yearly, windowStart: "2026-01-01T00:00:00.000", windowEnd: "2026-12-31T23:59:59.999", windowLabel: "2026", currentBoard: nil),
    ]
    ZStack {
        RisoPaperBackground()
        RisoCoreTimeframeGrid(slots: slots)
            .padding(Riso.gutter)
    }
}
#endif
