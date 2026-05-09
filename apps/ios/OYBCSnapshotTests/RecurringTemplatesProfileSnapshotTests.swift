import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Profile-tab `RecurringTemplatesView`
/// (Phase 6.2 UX rework, 2026-05-08). Replaces the older
/// `RecurringTemplatesSnapshotTests` (Create-tab section, deleted).
///
/// Two render variants:
///   - empty list (the "no templates yet" state)
///   - populated list with one active + one paused row
///
/// `RecurringTemplateRowView` lives in `Views/ProfileTab/` after the
/// rework move; its toggle/edit/delete affordances render whether
/// or not `onEditTemplate` is wired. The form-sheet variant isn't
/// snapshotted (form is `@State`-driven; manual QA covers it).
///
/// Fixtures use `.monthly` so window labels stay stable across days
/// (lesson from Phase 6.1d's daily-rendering issue).
final class RecurringTemplatesProfileSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // Note: the `RecurringTemplatesView` empty-state isn't snapshotted
    // because the view requires `@EnvironmentObject AuthService`, which
    // calls `FirebaseApp.configure()` on init — incompatible with the
    // snapshot harness (no Firebase config in the test target). The
    // empty-state copy is plain text + an SF Symbol; manual QA covers
    // its visual fidelity. The populated test below mounts the row
    // component directly for the same reason.

    /// Populated list — directly mounts a row stack that the view
    /// would render after `templatesVM.reloadAsync` completes. We
    /// bypass the view-model since AuthService + GRDB hydration is
    /// async and racy in a snapshot test; the row component itself
    /// is the visual unit being verified.
    func testPopulatedActiveAndPaused() {
        let active = SnapshotFixtures.makeRecurringTemplate(
            id: "tpl-1",
            name: "Daily Workout",
            timeframe: .monthly,
            boardSize: 5,
            isActive: true
        )
        let paused = SnapshotFixtures.makeRecurringTemplate(
            id: "tpl-2",
            name: "Weekly Reading",
            timeframe: .monthly,
            boardSize: 5,
            poolStrategy: .randomSubset,
            isActive: false
        )
        let view = NavigationStack {
            List {
                RecurringTemplateRowView(
                    template: active,
                    attentionReason: nil,
                    onEdit: {},
                    onTemplatesChanged: {}
                )
                RecurringTemplateRowView(
                    template: paused,
                    attentionReason: nil,
                    onEdit: {},
                    onTemplatesChanged: {}
                )
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Recurring templates")
            .navigationBarTitleDisplayMode(.inline)
        }
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 400)),
            record: recordMode
        )
    }
}
