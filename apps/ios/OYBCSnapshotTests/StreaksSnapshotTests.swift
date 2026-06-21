import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Streaks & history page (handoff §5e).
///
/// Snapshots the pure `StreaksContent` leaf (no env/DB/Firebase) in two
/// states — a healthy streak with history rows, and an empty/zero state —
/// each in light and dark mode.
///
/// `record: .missing` auto-records baselines on the first run.
/// CI overrides with `SNAPSHOT_TESTING_RECORD=never`.
final class StreaksSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Healthy state

    func testStreaksHealthyLight() {
        let view = healthyStreaksView()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 860)),
            record: recordMode
        )
    }

    func testStreaksHealthyDark() {
        let view = healthyStreaksView()
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 860),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Empty / zero state

    func testStreaksEmptyLight() {
        let view = emptyStreaksView()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 520)),
            record: recordMode
        )
    }

    func testStreaksEmptyDark() {
        let view = emptyStreaksView()
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 520),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Helpers

    private func healthyStreaksView() -> some View {
        // Fixed week dots: 5 filled + today empty — deterministic.
        let dots: [WeekDot] = [
            makeWeekDot(isFilled: true,  isToday: false),
            makeWeekDot(isFilled: true,  isToday: false),
            makeWeekDot(isFilled: true,  isToday: false),
            makeWeekDot(isFilled: false, isToday: false),
            makeWeekDot(isFilled: true,  isToday: false),
            makeWeekDot(isFilled: true,  isToday: false),
            makeWeekDot(isFilled: false, isToday: true),
        ]
        // Fixed history rows — no Date() dependency.
        let history: [StreakHistoryRow] = [
            StreakHistoryRow(id: "b1", name: "April Reading Sprint",   squares: 25, bingos: 3, timeframe: .monthly, relativeDate: "Today"),
            StreakHistoryRow(id: "b2", name: "Week 22 Workout",        squares: 9,  bingos: 1, timeframe: .weekly,  relativeDate: "May 31"),
            StreakHistoryRow(id: "b3", name: "Morning Routine",        squares: 9,  bingos: 2, timeframe: .daily,   relativeDate: "May 30"),
            StreakHistoryRow(id: "b4", name: "Q2 Goals",               squares: 25, bingos: 0, timeframe: .monthly, relativeDate: "Apr 30"),
        ]
        return NavigationStack {
            StreaksContent(
                currentStreak: 12,
                longestStreak: 24,
                greenlogCount: 37,
                weekDots: dots,
                historyRows: history
            )
        }
    }

    private func emptyStreaksView() -> some View {
        let dots: [WeekDot] = (0..<7).map { i in
            makeWeekDot(isFilled: false, isToday: i == 6)
        }
        return NavigationStack {
            StreaksContent(
                currentStreak: 0,
                longestStreak: 0,
                greenlogCount: 0,
                weekDots: dots,
                historyRows: []
            )
        }
    }

    /// Builds a WeekDot with a fixed reference date so snapshots don't embed
    /// today's real calendar day. The visual rendering depends only on
    /// `isFilled` and `isToday`, not on the date value.
    private func makeWeekDot(isFilled: Bool, isToday: Bool) -> WeekDot {
        WeekDot(date: SnapshotFixtures.fixedReferenceDate, isFilled: isFilled, isToday: isToday)
    }
}
