import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for the Phase 7 notification settings. Renders the
/// presentational leaf `NotificationPreferencesContent` (props + closures), so
/// — unlike the AuthService-bound container — it needs no Firebase/DB. Covers
/// the master-off, enabled, daily-time-expanded, and denied states.
@MainActor
final class NotificationPreferencesSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func prefs(master: Bool, daily: Bool = false) -> UserPreferences {
        var p = UserPreferences.defaults
        p.notificationsEnabled = master
        p.dailyPlayReminderEnabled = daily
        return p
    }

    func testMasterOffLight() {
        assertSnapshot(
            of: NotificationPreferencesContent(
                preferences: prefs(master: false), authorizationStatus: .notDetermined),
            as: .image(layout: .fixed(width: 393, height: 460)),
            record: recordMode
        )
    }

    func testEnabledLight() {
        assertSnapshot(
            of: NotificationPreferencesContent(
                preferences: prefs(master: true), authorizationStatus: .authorized),
            as: .image(layout: .fixed(width: 393, height: 720)),
            record: recordMode
        )
    }

    func testEnabledWithDailyTimeLight() {
        assertSnapshot(
            of: NotificationPreferencesContent(
                preferences: prefs(master: true, daily: true), authorizationStatus: .authorized),
            as: .image(layout: .fixed(width: 393, height: 800)),
            record: recordMode
        )
    }

    func testDeniedLight() {
        assertSnapshot(
            of: NotificationPreferencesContent(
                preferences: prefs(master: true), authorizationStatus: .denied),
            as: .image(layout: .fixed(width: 393, height: 480)),
            record: recordMode
        )
    }

    func testEnabledWithDailyTimeDark() {
        assertSnapshot(
            of: NotificationPreferencesContent(
                preferences: prefs(master: true, daily: true), authorizationStatus: .authorized),
            as: .image(
                layout: .fixed(width: 393, height: 800),
                traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }
}
