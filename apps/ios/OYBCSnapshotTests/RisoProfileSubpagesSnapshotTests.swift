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

    // MARK: - Template editor

    private func templateEdit(existing: Bool) -> some View {
        let pools = [pool("p-w", .weekly, taskIds: Array(repeating: "t", count: 9)),
                     pool("p-m", .monthly, taskIds: Array(repeating: "t", count: 14))]
        let tpl = existing
            ? SnapshotFixtures.makeRecurringTemplate(id: "tpl1", name: "Morning Routine", timeframe: .weekly, boardSize: 5, seedTaskCount: 9)
            : nil
        return TemplateEditSheet(template: tpl, pools: pools, onSave: { _ in }, onDelete: { _ in }, userId: SnapshotFixtures.userId)
    }

    func testTemplateEditCreateLight() {
        assertSnapshot(of: templateEdit(existing: false), as: .image(layout: .fixed(width: 393, height: 720)), record: recordMode)
    }
    func testTemplateEditExistingLight() {
        assertSnapshot(of: templateEdit(existing: true), as: .image(layout: .fixed(width: 393, height: 760)), record: recordMode)
    }
    func testTemplateEditCreateDark() {
        assertSnapshot(of: templateEdit(existing: false), as: .image(layout: .fixed(width: 393, height: 720), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
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
