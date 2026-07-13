import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for the Riso Profile sub-pages (handoff §5a) — the two new
/// editor sheets + Board Preferences. Renders the REAL views, seeded via
/// fixtures + an injected `AuthService`. The list pages
/// (`RecurringTemplatesView` / `DefaultPoolsListView`) self-load from
/// `AppDatabase.shared`, so they're not snapshotted here (covered by the
/// editors they present + Board Preferences).
@MainActor
final class RisoProfileSubpagesSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private let ts = SnapshotFixtures.fixedTimestamp

    private func pool(_ id: String, _ tf: Timeframe, taskIds: [String]) -> DefaultPool {
        DefaultPool(id: id, userId: SnapshotFixtures.userId, timeframe: tf, taskIds: taskIds,
                    createdAt: ts, updatedAt: ts, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil)
    }

    // MARK: - Recurring template card
    //
    // The inline TemplateEditSheet was retired (pool-only sheet could
    // underfill); creation/edit now route to the wizard. These guard the
    // list card component (`RecurringTemplateCard`) — the net-new surface
    // — in its healthy and "needs attention" states.

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

    // MARK: - Pool editor

    private func poolEdit(existing: Bool) -> some View {
        let tasks = [
            SnapshotFixtures.makeTask(id: "t1", title: "Drink water", type: .normal),
            SnapshotFixtures.makeTask(id: "t2", title: "Read 30 min", type: .normal),
            SnapshotFixtures.makeTask(id: "t3", title: "Run 5 km", type: .counting, action: "Run", unit: "km", maxCount: 5),
        ]
        let p = existing ? pool("p-w", .weekly, taskIds: ["t1", "t2"]) : nil
        return PoolEditSheet(pool: p, allTasks: tasks, onSave: { _ in }, onDelete: { _ in }, userId: SnapshotFixtures.userId)
    }

    func testPoolEditExistingLight() {
        assertSnapshot(of: poolEdit(existing: true), as: .image(layout: .fixed(width: 393, height: 640)), record: recordMode)
    }
    func testPoolEditExistingDark() {
        assertSnapshot(of: poolEdit(existing: true), as: .image(layout: .fixed(width: 393, height: 640), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    // BoardPreferencesView is deferred — it reads `@EnvironmentObject
    // AuthService` (+ AppDatabase.shared), which can't be constructed in a
    // snapshot test without FirebaseApp.configure(). Covered by manual review;
    // the two new editor sheets above are the net-new UI worth guarding.
}
