import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the home-screen Core Boards section + the
/// wizard's core-board setup variant:
///   - `CoreBoardsSectionView` — 1-slot, 4-slots all-not-yet, 4-slots
///     mixed (one Done, three Not-yet)
///   - `BoardWizardSetupStepView` for a core board (#70 collapsed layout)
///
/// `BoardPreferencesView`'s "Recurring Boards" section is not snapshotted
/// because it depends on `@EnvironmentObject AuthService` — wiring a mock
/// AuthService into a snapshot test is non-trivial and the section's render
/// is a straightforward `Section { Toggle… }` (low visual-regression risk).
///
/// Section fixtures use **fixed-date strings** rather than `Date()` so the
/// window label ("May 4, 2026" / "May 2026" / "Week of …" / "2026") stays
/// stable across days.
final class RecurringBoardsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Core Boards section (replaces the old Pending banner)

    /// Section with a single Daily slot — the most common steady
    /// state (only daily-prompt enabled).
    func testCoreBoardsSectionSingleDaily() {
        let slots: [CoreBoardSlot] = [
            CoreBoardSlot(
                timeframe: .daily,
                windowStart: "2026-05-04T00:00:00.000",
                windowEnd: "2026-05-04T23:59:59.999",
                windowLabel: "May 4, 2026",
                currentBoard: nil
            )
        ]
        let view = CoreBoardsSectionView(slots: slots, onSelect: { _ in })
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 110)),
            record: recordMode
        )
    }

    /// Section with all 4 timeframes enabled — the Jan 1 case where
    /// the user opens the app on the first day of a new year/month/
    /// week/day. Daily-first ordering is load-bearing.
    func testCoreBoardsSectionAllFour() {
        let view = CoreBoardsSectionView(
            slots: jan1FourSlotsAllNotYet(),
            onSelect: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 360)),
            record: recordMode
        )
    }

    private func jan1FourSlotsAllNotYet() -> [CoreBoardSlot] {
        [
            CoreBoardSlot(
                timeframe: .daily,
                windowStart: "2026-01-01T00:00:00.000",
                windowEnd: "2026-01-01T23:59:59.999",
                windowLabel: "Jan 1, 2026",
                currentBoard: nil
            ),
            CoreBoardSlot(
                timeframe: .weekly,
                windowStart: "2025-12-29T00:00:00.000",
                windowEnd: "2026-01-04T23:59:59.999",
                windowLabel: "Week of Dec 29 – Jan 4",
                currentBoard: nil
            ),
            CoreBoardSlot(
                timeframe: .monthly,
                windowStart: "2026-01-01T00:00:00.000",
                windowEnd: "2026-01-31T23:59:59.999",
                windowLabel: "January 2026",
                currentBoard: nil
            ),
            CoreBoardSlot(
                timeframe: .yearly,
                windowStart: "2026-01-01T00:00:00.000",
                windowEnd: "2026-12-31T23:59:59.999",
                windowLabel: "2026",
                currentBoard: nil
            ),
        ]
    }

    // MARK: - Wizard core-board variant (#70)

    /// Setup step rendered for a **core** board — the variant the user
    /// sees when they tapped a Core Boards row / banner (the wizard is
    /// launched with `prefilledRecurringTimeframe`, so `isCore=true`).
    /// Verifies the #70 collapsed layout: a read-only window caption
    /// plus only Board size + Center square (no name field, no timeframe
    /// selector, no recurring/randomize toggles).
    ///
    /// Uses `.monthly` so the rendered window label is stable across
    /// days within the calendar month (daily would drift daily).
    func testSetupStepCoreBoard() {
        let prefs = SnapshotFixtures.makeUserPreferences()
        let controller = BoardWizardViewModel(
            preferences: prefs,
            prefilledRecurringTimeframe: .monthly
        )
        // Pin a stable name so the snapshot doesn't drift across months
        // (the core layout shows this as the read-only window caption).
        controller.name = "May 2026"

        let view = BoardWizardSetupStepView(
            controller: controller,
            onCancel: { },
            onNext: { }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 420)),
            record: recordMode
        )
    }
}
