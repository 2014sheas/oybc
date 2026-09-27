import Foundation

// MARK: - Board sealing detection (Swift port of algorithms/sealing.ts)
//
// Swift port of `packages/shared/src/algorithms/sealing.ts` (Windowed
// Completion, docs/WINDOWED_COMPLETION.md §Sealing → Lifecycle + Backstop,
// §Migration step 3, §Edge cases). Pure predicates that own the "which boards
// can/should seal" decision so both platforms + the migration agree
// byte-for-byte. The TS file is the source of truth.

/// Whether a board is eligible to seal at all (docs §Lifecycle → Detection): a
/// real, closeable window that isn't already sealed. Excludes soft-deleted,
/// already-sealed, DRAFT, and indefinite boards. Archived boards ARE sealable
/// (archived is a status, orthogonal to sealing). Mirrors `isBoardSealable`.
func isBoardSealable(_ board: Board) -> Bool {
    if board.isDeleted { return false }
    if board.sealedAt != nil { return false }
    if board.status == .draft { return false }
    if board.isIndefinite { return false }
    return true
}

/// Whether a board's window has closed and it awaits close-out (docs §Lifecycle
/// → Detection: the "closing-out set"). Sealable AND its `endDate` is strictly
/// before `now`. The prompt set (banner UX is slice 2). Mirrors
/// `isBoardClosingOut`.
///
/// - Parameters:
///   - board: The board to test.
///   - nowMs: Current time as epoch ms.
func isBoardClosingOut(_ board: Board, nowMs: Double) -> Bool {
    guard isBoardSealable(board) else { return false }
    guard let endDate = board.endDate, let end = DateFormatting.parseISO(endDate) else { return false }
    return end.timeIntervalSince1970 * 1000 < nowMs
}

/// Custom-window auto-close grace bounds, in whole local days (D4 / OQ1).
/// Mirrors the TS `CUSTOM_AUTO_CLOSE_MIN_DAYS` / `CUSTOM_AUTO_CLOSE_MAX_DAYS`.
let customAutoCloseMinDays = 1
let customAutoCloseMaxDays = 31

private let dayMs: Double = 24 * 60 * 60 * 1000

/// The end of the window AFTER a board's own window, as epoch ms — the "next
/// window of that timeframe" (Board Edit redesign slice 4, D4 / owner ruling
/// R5). Local wall-clock arithmetic on `end`'s components (the `stepWindow`
/// convention), so a DST change inside the grace never shifts the result:
/// DAILY +1 local day; WEEKLY +7; MONTHLY → last day of the month after
/// `end`'s month; YEARLY → Dec 31 of the next year (all at `end`'s wall time);
/// CUSTOM → + the window's own length in whole local days (rounded), clamped
/// to [1, 31]. Mirrors the TS `nextWindowEndMs`.
private func nextWindowEndMs(timeframe: Timeframe, startDate: String, end: Date) -> Double? {
    let cal = Calendar.current
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: end)
    guard let year = c.year, let month = c.month, let day = c.day else { return nil }

    /// A date at `end`'s wall-clock time on the given (possibly overflowing)
    /// calendar day — `Calendar` normalises day/month overflow like JS `Date`.
    func wallClock(year: Int, month: Int, day: Int) -> Double? {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = c.hour; comps.minute = c.minute; comps.second = c.second
        comps.nanosecond = c.nanosecond
        return cal.date(from: comps).map { ($0.timeIntervalSince1970 * 1000).rounded() }
    }

    func plusDays(_ n: Int) -> Double? {
        guard let startOfEndDay = cal.date(from: DateComponents(year: year, month: month, day: day)),
              let target = cal.date(byAdding: .day, value: n, to: startOfEndDay) else { return nil }
        let t = cal.dateComponents([.year, .month, .day], from: target)
        guard let ty = t.year, let tm = t.month, let td = t.day else { return nil }
        return wallClock(year: ty, month: tm, day: td)
    }

    switch timeframe {
    case .daily:
        return plusDays(1)
    case .weekly:
        return plusDays(7)
    case .monthly:
        // The month after `end`'s month; its last day.
        guard let firstOfEndMonth = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let firstOfNext = cal.date(byAdding: .month, value: 1, to: firstOfEndMonth),
              let daysInNext = cal.range(of: .day, in: .month, for: firstOfNext)?.count else { return nil }
        let n = cal.dateComponents([.year, .month], from: firstOfNext)
        guard let ny = n.year, let nm = n.month else { return nil }
        return wallClock(year: ny, month: nm, day: daysInNext)
    case .yearly:
        return wallClock(year: year + 1, month: 12, day: 31)
    case .custom, .indefinite:
        let startMs = DateFormatting.parseISO(startDate).map { $0.timeIntervalSince1970 * 1000 }
        let lengthDays = startMs.map { Int(((end.timeIntervalSince1970 * 1000 - $0) / dayMs).rounded()) } ?? 0
        let grace = min(customAutoCloseMaxDays, max(customAutoCloseMinDays, lengthDays))
        return plusDays(grace)
    }
}

/// The absolute auto-close deadline for a board, as epoch ms (Board Edit
/// redesign slice 4, D4 — replaces the old `min(48h, len/4)` backstop): the
/// end of the NEXT window of the board's timeframe. A draft activated AFTER its
/// window ended gets the same grace from `activatedAt` —
/// `max(next(endDate), activatedAt + (next(endDate) − endDate))`. Mirrors the
/// TS `computeAutoCloseDeadlineMs`.
///
/// - Parameters:
///   - timeframe: The board's timeframe.
///   - startDate: Window start (ISO8601; only CUSTOM reads it).
///   - endDate: Window end (ISO8601), nil for indefinite.
///   - activatedAt: When the board was activated (ISO8601), if known.
/// - Returns: Epoch-ms deadline (whole ms), or `nil` when the board never
///   auto-closes (indefinite / no or unparseable `endDate`).
func computeAutoCloseDeadlineMs(
    timeframe: Timeframe,
    startDate: String,
    endDate: String?,
    activatedAt: String? = nil
) -> Double? {
    guard timeframe != .indefinite, let endDate, let end = DateFormatting.parseISO(endDate) else { return nil }
    guard let nextMs = nextWindowEndMs(timeframe: timeframe, startDate: startDate, end: end) else { return nil }
    guard let activated = activatedAt.flatMap(DateFormatting.parseISO) else { return nextMs }
    let endMs = (end.timeIntervalSince1970 * 1000).rounded()
    let activatedMs = (activated.timeIntervalSince1970 * 1000).rounded()
    return max(nextMs, activatedMs + (nextMs - endMs))
}

/// Whether a board is past its auto-close deadline (docs §Lifecycle →
/// auto-close; the name keeps "backstop" to limit churn). Sealable, NOT
/// manually reopened (`reopenedAt` set → never auto-closes, D1), and `now`
/// strictly beyond `computeAutoCloseDeadlineMs`. Both the lazy app-open
/// auto-close check and the migration's expired-board sealing gate on this.
/// Mirrors `isBoardPastBackstop`.
///
/// - Parameters:
///   - board: The board to test.
///   - nowMs: Current time as epoch ms.
func isBoardPastBackstop(_ board: Board, nowMs: Double) -> Bool {
    guard isBoardSealable(board) else { return false }
    guard board.reopenedAt == nil else { return false }
    guard let deadline = computeAutoCloseDeadlineMs(
        timeframe: board.timeframe,
        startDate: board.startDate,
        endDate: board.endDate,
        activatedAt: board.activatedAt
    ) else { return false }
    return nowMs > deadline
}

/// Whether a board is **Ended, not closed** (Board Edit redesign slice 4,
/// D12): its window is over and it is still unsealed, so it keeps accepting
/// logs (stamped at its `endDate`) until the user closes it or it auto-closes.
/// `isBoardClosingOut` restricted to non-archived boards (no Close/Reopen on
/// archived — OQ5). Mirrors the TS `isBoardEnded`.
///
/// - Parameters:
///   - board: The board to test.
///   - nowMs: Current time as epoch ms.
func isBoardEnded(_ board: Board, nowMs: Double) -> Bool {
    guard board.status != .archived else { return false }
    return isBoardClosingOut(board, nowMs: nowMs)
}

/// Whether a board is **Closed** (Board Edit redesign slice 4, D12): sealed,
/// not deleted, and ACTIVE or COMPLETED (archived boards get no Close/Reopen —
/// OQ5). Mirrors the TS `isBoardClosed`.
///
/// - Parameter board: The board to test.
func isBoardClosed(_ board: Board) -> Bool {
    guard !board.isDeleted, board.sealedAt != nil else { return false }
    return board.status == .active || board.status == .completed
}

/// Whether board-PLAY interactions are locked (docs §Effects of sealed —
/// "Not editable": tap-to-complete, counter stepper, context-menu actions,
/// the empty-cell "+" add affordance, and the toolbar Edit entry point).
/// `BoardPlayView.isBoardLocked` composes this predicate.
///
/// A board locks when — and only when — it is SEALED. Sealing REPLACES the
/// old expiry-based interaction lock: per docs §Sealing → Lifecycle, an
/// expired-but-unsealed board is "still fully live" (the closing-out
/// banner's **Log** action depends on this — the 11:58pm workout logged at
/// 12:04am from the closing daily's own surface is stamped at its `endDate`
/// and counts for the closing daily), and next-window auto-close bounds the
/// overtime, after which the board closes. A sealed board locks ORDINARY
/// play; its squares route to the closed-board late-log sheet instead
/// (`AppDatabase+LateLog.swift`), and Reopen clears the seal (Board Edit
/// redesign slice 4).
///
/// Extracted as a standalone pure function (rather than left inline in the
/// view) so the gating rule is unit-testable without instantiating SwiftUI.
///
/// - Parameter board: The board to test.
/// - Returns: `true` iff every play interaction should be disabled.
func isBoardPlayLocked(_ board: Board) -> Bool {
    board.sealedAt != nil
}
