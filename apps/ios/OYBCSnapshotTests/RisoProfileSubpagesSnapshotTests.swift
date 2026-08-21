import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for the Riso Profile sub-pages (handoff §5a) — Board
/// Preferences + the `RecurringTemplateCard` component that now powers the
/// P7 Board-settings "Repeating boards" roster. Renders the REAL views,
/// seeded via fixtures + an injected `AuthService`.
///
/// P7 (Task Pools + Recurring Boards Rework) retired the `RecurringTemplatesView`
/// / `DefaultPoolsListView` pages (and the `PoolEditSheet` /
/// `DefaultPool`-scoped tests that used to guard the latter's editor) in
/// favor of `BoardSettingsView`. `BoardSettingsView` itself self-loads
/// from `AppDatabase.shared` + `@EnvironmentObject AuthService` (same
/// reason the two retired list pages were never snapshotted here — see
/// the CLAUDE.md snapshot-testing sharp edges section), so it's not
/// snapshotted directly; its two DB-free, props-only sheets
/// (`CoreDefaultsEditSheetView`, `RepeatingBoardEditSheetView`) and the
/// shared `PoolPickerSheetView` are covered in
/// `BoardSettingsSnapshotTests.swift` instead, following the exact
/// pattern `PoolEditSheetView` already proved safe in `RisoPoolsSnapshotTests`.
@MainActor
final class RisoProfileSubpagesSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Recurring template card
    //
    // The inline TemplateEditSheet was retired (pool-only sheet could
    // underfill); creation/edit now route to a local sheet
    // (`RepeatingBoardEditSheetView`, P7). These guard the list card
    // component (`RecurringTemplateCard`) — reused verbatim as the P7
    // Board-settings roster's row — in its healthy and "needs attention"
    // states, plus a multi-row "list" arrangement (active + paused).

    /// Issue #321 — pool-preview chip row (first 3 resolved titles + "+{k}
    /// more" overflow) and the "Add tasks" affordance in `metaRow`. Both
    /// grow the card's height, so the fixed heights below are bumped from
    /// the pre-#321 130/180 baselines to avoid clipping.
    private func templateCard(
        attention: SpawnPoolFailureReason?,
        isActive: Bool = true,
        poolPreview: [String] = ["Drink water", "Read 30 min", "Run 5 km"],
        poolPreviewOverflow: Int = 6
    ) -> some View {
        let tpl = SnapshotFixtures.makeRecurringTemplate(
            id: "tpl1", name: "Morning Routine", timeframe: .weekly,
            boardSize: 5, seedTaskCount: 9, isActive: isActive
        )
        return RecurringTemplateCard(
            template: tpl,
            attentionReason: attention,
            poolPreview: poolPreview,
            poolPreviewOverflow: poolPreviewOverflow,
            onEdit: {}, onToggleActive: { _ in }, onDelete: {}, onAddTasks: {}
        )
        .padding(Riso.gutter)
        .background(Color.risoPaper)
    }

    func testTemplateCardHealthyLight() {
        assertSnapshot(of: templateCard(attention: nil), as: .image(layout: .fixed(width: 393, height: 180)), record: recordMode)
    }
    func testTemplateCardAttentionLight() {
        assertSnapshot(of: templateCard(attention: .poolTooSmall), as: .image(layout: .fixed(width: 393, height: 230)), record: recordMode)
    }
    func testTemplateCardAttentionDark() {
        assertSnapshot(of: templateCard(attention: .poolTooSmall), as: .image(layout: .fixed(width: 393, height: 230), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    // MARK: - Roster list (P7) — active + paused rows together, standing
    // in for `BoardSettingsView`'s "Repeating boards" section (which
    // itself can't be snapshotted — see the file header doc).

    private func rosterList() -> some View {
        let active = SnapshotFixtures.makeRecurringTemplate(
            id: "tpl-active", name: "Morning Routine", timeframe: .weekly,
            boardSize: 5, seedTaskCount: 9, isActive: true
        )
        let paused = SnapshotFixtures.makeRecurringTemplate(
            id: "tpl-paused", name: "Weekend Reset", timeframe: .weekly,
            boardSize: 3, seedTaskCount: 8, isActive: false
        )
        return VStack(spacing: 10) {
            RecurringTemplateCard(
                template: active, attentionReason: nil,
                poolPreview: ["Drink water", "Read 30 min"], poolPreviewOverflow: 0,
                onEdit: {}, onToggleActive: { _ in }, onDelete: {}, onAddTasks: {}
            )
            RecurringTemplateCard(
                template: paused, attentionReason: nil,
                poolPreview: ["Meal prep"], poolPreviewOverflow: 0,
                onEdit: {}, onToggleActive: { _ in }, onDelete: {}, onAddTasks: {}
            )
        }
        .padding(Riso.gutter)
        .background(Color.risoPaper)
    }

    func testRosterListLight() {
        assertSnapshot(of: rosterList(), as: .image(layout: .fixed(width: 393, height: 300)), record: recordMode)
    }
    func testRosterListDark() {
        assertSnapshot(of: rosterList(), as: .image(layout: .fixed(width: 393, height: 300), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    // BoardPreferencesView is deferred — it reads `@EnvironmentObject
    // AuthService` (+ AppDatabase.shared), which can't be constructed in a
    // snapshot test without FirebaseApp.configure(). Covered by manual review.
}
