import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for Phase 6.1's net-new visual surfaces:
///   - `PendingCoreBoardsSectionView` — boards-tab + create-tab variants,
///     1-entry + 4-entry (Jan 1 case)
///   - `BoardSetupFormView` with `lockTimeframe: true`
///
/// `BoardPreferencesView`'s new "Recurring Boards" section is not snapshotted
/// because it depends on `@EnvironmentObject AuthService` — wiring a mock
/// AuthService into a snapshot test is non-trivial and the section's render
/// is a straightforward `Section { Toggle… }` (low visual-regression risk).
/// Add a dedicated test if AuthService gains a snapshot-friendly initializer.
///
/// Section fixtures use **fixed-date strings** rather than `Date()` so the
/// suggested-name label ("May 4, 2026" / "May 2026" / "Week of …" / "2026")
/// stays stable across days.
final class RecurringBoardsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Section (Phase 6.1d — replaces the older banner)

    /// Section with a single Daily entry — the most common steady-state
    /// case (user has daily-prompt enabled, opens the app on a new day,
    /// no other windows are pending). Tests the `.boardsTab` variant.
    func testSectionSingleDailyEntry() {
        let pending = [
            PendingRecurringBoard(
                timeframe: .daily,
                startDate: "2026-05-04T00:00:00.000",
                endDate: "2026-05-04T23:59:59.999",
                suggestedName: "May 4, 2026"
            )
        ]
        let view = PendingCoreBoardsSectionView(
            pending: pending,
            variant: .boardsTab,
            onCreate: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 110)),
            record: recordMode
        )
    }

    /// Section with all four timeframes pending — the Jan 1 case where
    /// the user opens the app on the first day of a new year/month/
    /// week/day simultaneously. Order is load-bearing (longest-window-
    /// first) so the wizard's "From parent boards" filter has a usable
    /// parent chain. Tests the `.boardsTab` variant.
    func testSectionAllFourEntriesJan1BoardsTab() {
        let pending = jan1FourEntryFixture()
        let view = PendingCoreBoardsSectionView(
            pending: pending,
            variant: .boardsTab,
            onCreate: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 360)),
            record: recordMode
        )
    }

    /// Same fixture as the boards-tab variant but mounted on the Create
    /// tab. Verifies the heading copy difference ("Get started with
    /// today's boards" vs "Pending boards") and confirms the cards
    /// themselves render identically across surfaces.
    func testSectionAllFourEntriesJan1CreateTab() {
        let pending = jan1FourEntryFixture()
        let view = PendingCoreBoardsSectionView(
            pending: pending,
            variant: .createTab,
            onCreate: { _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 360)),
            record: recordMode
        )
    }

    private func jan1FourEntryFixture() -> [PendingRecurringBoard] {
        [
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
    }

    // MARK: - Wizard prefill (locked timeframe variant)

    /// Setup step rendered with `lockTimeframe=true` — the variant the user
    /// sees when they tapped Create on a banner row. Verifies the locked-
    /// chip variant (single disabled segmented button + hint copy) renders
    /// correctly in place of the full segmented selector.
    ///
    /// Uses `.monthly` rather than `.daily` for the test fixture so the
    /// rendered date display is stable across days within the calendar
    /// month (daily would drift the snapshot every day; monthly only
    /// drifts on the 1st of the month, matching the existing
    /// `testSetupStepValid` pattern).
    func testSetupStepLockedMonthlyTimeframe() {
        let prefs = SnapshotFixtures.makeUserPreferences()
        let controller = BoardWizardViewModel(
            preferences: prefs,
            prefilledRecurringTimeframe: .monthly
        )
        // Pin a stable name so the snapshot doesn't drift across months.
        controller.name = "May 2026"

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
