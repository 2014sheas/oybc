import Foundation

// MARK: - Streaks
//
// iOS mirror of `packages/shared/src/algorithms/streaks.ts`. Pure functions
// over the local `boards` table — consecutive recurring core-board windows
// (per timeframe) the user "achieved".
//
// Two criteria, keyed off the same thresholds as Achievement watcher tasks:
//   - .bingo    → the window's core board has `linesCompleted >= 1`.
//   - .greenlog → the window's core board is `.completed` (full board).
//
// Core boards only (`isCore`). Computed live from board state (no separate
// persisted log) — offline-first + auto-consistent across devices; the
// trade-off is that un-completing a task on an old board can retroactively
// shift its streak.
//
// Rules: walk windows backward from `now`; the CURRENT window gets grace (not
// achieving it yet never breaks the streak); any CLOSED window with no core
// board, or whose board didn't meet the criterion, ends the streak.
//
// Canonical design: docs (Streaks). Keep in lock-step with the TS twin.

/// The four recurring timeframes streaks apply to (`.custom` has no cadence).
private let streakTimeframes: [Timeframe] = [.daily, .weekly, .monthly, .yearly]

/// Safety backstop on how many windows we walk back. Real streaks are bounded
/// by board history (the first window with no core board breaks the loop).
private let maxStreakWindows = 1000

/// A timeframe's two streak counts.
struct StreakPair: Equatable {
    let bingo: Int
    let greenlog: Int
}

/// Whether a core board satisfies the streak criterion. Mirrors the Achievement
/// trigger semantics (bingo = `linesCompleted >= 1`, greenlog = full board).
private func boardMeets(_ board: Board, _ criterion: AchievementTrigger) -> Bool {
    switch criterion {
    case .bingo:    return board.linesCompleted >= 1
    case .greenlog: return board.status == .completed
    }
}

/// Current streak for one timeframe + criterion. Returns 0 for `.custom` or when
/// no core boards exist.
///
/// - Parameters:
///   - timeframe: daily/weekly/monthly/yearly (`.custom` → 0).
///   - criterion: `.bingo` or `.greenlog`.
///   - boards: all boards for the active user (caller scopes by userId).
///   - weekStartDay: `"monday"` / `"sunday"` — only affects weekly windows.
///   - now: reference instant (injected for determinism / testing).
func computeStreak(
    timeframe: Timeframe,
    criterion: AchievementTrigger,
    boards: [Board],
    weekStartDay: String,
    now: Date
) -> Int {
    guard timeframe != .custom else { return 0 }

    // startDate → the core board for that window. Core boards write `startDate`
    // via `wizardLocalISOString(window.start)`, the exact string the boundary
    // helper produces, so window→board matching is a string-key lookup.
    var byStart: [String: Board] = [:]
    for board in boards where board.isCore && !board.isDeleted && board.timeframe == timeframe {
        byStart[board.startDate] = board
    }
    if byStart.isEmpty { return 0 }

    guard let current = computeTimeframeBoundaries(
        timeframe: timeframe, referenceDate: now, weekStartDay: weekStartDay
    ) else { return 0 }

    var streak = 0
    var startISO = wizardLocalISOString(current.start)
    var isCurrent = true

    for _ in 0..<maxStreakWindows {
        let achieved = byStart[startISO].map { boardMeets($0, criterion) } ?? false

        if achieved {
            streak += 1
        } else if !isCurrent {
            // A closed window with no achieving core board ends the streak.
            break
        }
        // (current window not achieved → grace: don't break, keep walking back.)

        guard let prev = stepCoreBoardWindow(
            timeframe: timeframe, fromStartIso: startISO, step: -1, weekStartDay: weekStartDay
        ) else { break }
        startISO = wizardLocalISOString(prev.start)
        isCurrent = false
    }

    return streak
}

/// Both streak kinds for all four recurring timeframes in one pass.
func computeAllStreaks(
    boards: [Board],
    weekStartDay: String,
    now: Date
) -> [Timeframe: StreakPair] {
    var out: [Timeframe: StreakPair] = [:]
    for tf in streakTimeframes {
        out[tf] = StreakPair(
            bingo: computeStreak(timeframe: tf, criterion: .bingo, boards: boards, weekStartDay: weekStartDay, now: now),
            greenlog: computeStreak(timeframe: tf, criterion: .greenlog, boards: boards, weekStartDay: weekStartDay, now: now)
        )
    }
    return out
}
