import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for Phase 6.1's net-new visual surfaces:
///   - `RecurringBoardsBannerView` (1-entry + 4-entry / Jan 1 case)
///   - `BoardSetupFormView` with `lockTimeframe: true`
///
/// `BoardPreferencesView`'s new "Recurring Boards" section is not snapshotted
/// because it depends on `@EnvironmentObject AuthService` — wiring a mock
/// AuthService into a snapshot test is non-trivial and the section's render
/// is a straightforward `Section { Toggle… }` (low visual-regression risk).
/// Add a dedicated test if AuthService gains a snapshot-friendly initializer.
///
/// Banner fixtures use **fixed-date strings** rather than `Date()` so the
/// suggested-name label ("May 2, 2026" / "May 2026" / "Week of …" / "2026")
/// stays stable across days.
final class RecurringBoardsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Banner

    /// Banner with a single Daily entry — the most common steady-state
    /// case (user has daily-prompt enabled, opens the app on a new day,
    /// no other windows are pending).
    func testBannerSingleDailyEntry() {
        let pending = [
            PendingRecurringBoard(
                timeframe: .daily,
                startDate: "2026-05-02T00:00:00.000",
                endDate: "2026-05-02T23:59:59.999",
                suggestedName: "May 2, 2026"
            )
        ]
        let view = RecurringBoardsBannerView(pending: pending, onCreate: { _ in })
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 140)),
            record: recordMode
        )
    }

    /// Banner with all four timeframes pending — the Jan 1 case where the
    /// user opens the app on the first day of a new year/month/week/day
    /// simultaneously. Order is load-bearing (longest-window-first) so the
    /// wizard's "From parent boards" filter has a usable parent chain.
    func testBannerAllFourEntriesJan1() {
        let pending = [
            PendingRecurringBoard(
                timeframe: .yearly,
                startDate: "2026-01-01T00:00:00.000",
                endDate: "2026-12-31T23:59:59.999",
                suggestedName: "2026"
            ),
            PendingRecurringBoard(
                timeframe: .monthly,
                startDate: "2026-01-01T00:00:00.000",
                endDate: "2026-01-31T23:59:59.999",
                suggestedName: "January 2026"
            ),
            PendingRecurringBoard(
                timeframe: .weekly,
                startDate: "2025-12-29T00:00:00.000",
                endDate: "2026-01-04T23:59:59.999",
                suggestedName: "Week of Dec 29 – Jan 4"
            ),
            PendingRecurringBoard(
                timeframe: .daily,
                startDate: "2026-01-01T00:00:00.000",
                endDate: "2026-01-01T23:59:59.999",
                suggestedName: "Jan 1, 2026"
            ),
        ]
        let view = RecurringBoardsBannerView(pending: pending, onCreate: { _ in })
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 320)),
            record: recordMode
        )
    }

    // MARK: - Wizard prefill (locked timeframe variant)

    /// Setup step rendered with `lockTimeframe=true` — the variant the user
    /// sees when they tapped Create on a banner row. Verifies the locked-
    /// chip variant (single disabled segmented button + hint copy) renders
    /// correctly in place of the full segmented selector.
    func testSetupStepLockedDailyTimeframe() {
        let prefs = SnapshotFixtures.makeUserPreferences()
        let controller = BoardWizardViewModel(
            preferences: prefs,
            prefilledRecurringTimeframe: .daily
        )
        // Pin a stable name so the snapshot doesn't drift across days
        // (the prefill seeds the name from formatTimeframeLabel which
        // returns "Today" only on the same calendar day).
        controller.name = "May 2, 2026"

        let view = BoardWizardSetupStepView(
            controller: controller,
            lockTimeframe: true,
            onCancel: { },
            onNext: { }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }
}
