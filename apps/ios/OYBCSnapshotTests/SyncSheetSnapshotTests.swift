import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Sync detail sheet (handoff §5d).
///
/// Snapshots the pure `SyncSheet` leaf for all 4 states (synced, syncing,
/// offline, error) × light and dark — no live `SyncService` needed.
///
/// `record: .missing` auto-records baselines on the first run.
/// CI overrides with `SNAPSHOT_TESTING_RECORD=never`.
final class SyncSheetSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Synced

    func testSyncedLight() {
        assertSnapshot(
            of: syncSheetView(state: .synced(lastSyncedAt: fixedDate)),
            as: .image(layout: .fixed(width: 393, height: 440)),
            record: recordMode
        )
    }

    func testSyncedDark() {
        assertSnapshot(
            of: syncSheetView(state: .synced(lastSyncedAt: fixedDate)),
            as: .image(
                layout: .fixed(width: 393, height: 440),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Syncing

    func testSyncingLight() {
        assertSnapshot(
            of: syncSheetView(state: .syncing),
            as: .image(layout: .fixed(width: 393, height: 440)),
            record: recordMode
        )
    }

    func testSyncingDark() {
        assertSnapshot(
            of: syncSheetView(state: .syncing),
            as: .image(
                layout: .fixed(width: 393, height: 440),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Offline

    func testOfflineLight() {
        assertSnapshot(
            of: syncSheetView(state: .offline),
            as: .image(layout: .fixed(width: 393, height: 490)),
            record: recordMode
        )
    }

    func testOfflineDark() {
        assertSnapshot(
            of: syncSheetView(state: .offline),
            as: .image(
                layout: .fixed(width: 393, height: 490),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Error

    func testErrorLight() {
        assertSnapshot(
            of: syncSheetView(state: .error),
            as: .image(layout: .fixed(width: 393, height: 490)),
            record: recordMode
        )
    }

    func testErrorDark() {
        assertSnapshot(
            of: syncSheetView(state: .error),
            as: .image(
                layout: .fixed(width: 393, height: 490),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Synced with nil lastSyncedAt (never synced)

    func testSyncedNeverLight() {
        assertSnapshot(
            of: syncSheetView(state: .synced(lastSyncedAt: nil)),
            as: .image(layout: .fixed(width: 393, height: 440)),
            record: recordMode
        )
    }

    // MARK: - Exhausted items (D1)

    func testSyncedWithExhaustedItemsLight() {
        assertSnapshot(
            of: SyncSheet(
                state: .synced(lastSyncedAt: fixedDate),
                exhaustedCount: 3,
                now: SnapshotFixtures.fixedReferenceDate
            ),
            as: .image(layout: .fixed(width: 393, height: 560)),
            record: recordMode
        )
    }

    func testSyncedWithExhaustedItemsDark() {
        assertSnapshot(
            of: SyncSheet(
                state: .synced(lastSyncedAt: fixedDate),
                exhaustedCount: 3,
                now: SnapshotFixtures.fixedReferenceDate
            ),
            as: .image(
                layout: .fixed(width: 393, height: 560),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Helpers

    /// Renders with `now` pinned to `SnapshotFixtures.fixedReferenceDate`, so
    /// the relative "last backup" label is stable across runs.
    private func syncSheetView(state: SyncSheetState) -> some View {
        SyncSheet(state: state, now: SnapshotFixtures.fixedReferenceDate)
    }

    /// Five minutes before the pinned `now`, so the synced label reads as a
    /// fixed "5 min. ago"-style string (wording is the formatter's).
    private var fixedDate: Date {
        SnapshotFixtures.fixedReferenceDate.addingTimeInterval(-300)
    }
}
