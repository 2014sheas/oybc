import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for the Riso Profile sub-pages (handoff §5a) — the
/// `RecurringTemplateCard` component that now powers the Board-settings
/// "REPEATING BOARDS" roster. Renders the REAL component directly.
///
/// `BoardSettingsView` (the container) still self-loads from
/// `AppDatabase.shared` + `@EnvironmentObject AuthService` (same reason the
/// two retired list pages were never snapshotted here — see the CLAUDE.md
/// snapshot-testing sharp edges section), so it's not snapshotted directly;
/// its DB-free, props-only `CoreDefaultsEditSheetView` and the shared
/// `PoolPickerSheetView` — plus, since Profile reorg PR3, the full
/// restructured screen via the presentational `BoardSettingsContent` leaf —
/// are covered in `BoardSettingsSnapshotTests.swift` instead.
@MainActor
final class RisoProfileSubpagesSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Recurring template row
    //
    // Profile reorg PR3 dropped the pool-preview chip row, "Add tasks", and
    // inline "Delete" from this component (now a plain row — the card
    // chrome moved out to the composite card `BoardSettingsContent` wraps
    // every row in), so these fixed heights are much shorter than the
    // pre-PR3 baselines. Guards the row in its healthy and "needs
    // attention" states, plus a multi-row "list" arrangement (active +
    // paused) wrapped the same way `BoardSettingsContent.rosterCard` does.

    private func templateRow(
        attention: SpawnAttentionReason?,
        isActive: Bool = true
    ) -> some View {
        let tpl = SnapshotFixtures.makeRecurringTemplate(
            id: "tpl1", name: "Morning Routine", timeframe: .weekly,
            boardSize: 5, seedTaskCount: 9, isActive: isActive
        )
        return RecurringTemplateCard(
            template: tpl,
            attentionReason: attention,
            weekStartDay: .monday,
            onEdit: {}, onToggleActive: { _ in }
        )
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .padding(Riso.gutter)
        .background(Color.risoPaper)
    }

    func testTemplateCardHealthyLight() {
        assertSnapshot(of: templateRow(attention: nil), as: .image(layout: .fixed(width: 393, height: 100)), record: recordMode)
    }
    func testTemplateCardAttentionLight() {
        assertSnapshot(of: templateRow(attention: .poolTooSmall), as: .image(layout: .fixed(width: 393, height: 150)), record: recordMode)
    }
    func testTemplateCardAttentionDark() {
        assertSnapshot(of: templateRow(attention: .poolTooSmall), as: .image(layout: .fixed(width: 393, height: 150), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    // MARK: - Roster list — active + paused rows in ONE composite card,
    // standing in for `BoardSettingsView`'s "REPEATING BOARDS" section
    // (the container itself can't be snapshotted — see the file header doc).

    private func rosterList() -> some View {
        let active = SnapshotFixtures.makeRecurringTemplate(
            id: "tpl-active", name: "Morning Routine", timeframe: .weekly,
            boardSize: 5, seedTaskCount: 9, isActive: true
        )
        let paused = SnapshotFixtures.makeRecurringTemplate(
            id: "tpl-paused", name: "Weekend Reset", timeframe: .weekly,
            boardSize: 3, seedTaskCount: 8, isActive: false
        )
        return VStack(spacing: 0) {
            RecurringTemplateCard(
                template: active, attentionReason: nil, weekStartDay: .monday,
                onEdit: {}, onToggleActive: { _ in }
            )
            Divider().background(Color.risoInk.opacity(0.12)).padding(.horizontal, Riso.cardPadding)
            RecurringTemplateCard(
                template: paused, attentionReason: nil, weekStartDay: .monday,
                onEdit: {}, onToggleActive: { _ in }
            )
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .padding(Riso.gutter)
        .background(Color.risoPaper)
    }

    func testRosterListLight() {
        assertSnapshot(of: rosterList(), as: .image(layout: .fixed(width: 393, height: 170)), record: recordMode)
    }
    func testRosterListDark() {
        assertSnapshot(of: rosterList(), as: .image(layout: .fixed(width: 393, height: 170), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    // BoardPreferencesView is deferred — it reads `@EnvironmentObject
    // AuthService` (+ AppDatabase.shared), which can't be constructed in a
    // snapshot test without FirebaseApp.configure(). Covered by manual review.
}
