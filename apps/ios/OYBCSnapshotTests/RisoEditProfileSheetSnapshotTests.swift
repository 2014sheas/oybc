import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `EditProfileSheet` (§5b of the Riso redesign).
///
/// The sheet is a pure-props view that takes displayName / email / mood
/// as init parameters. `AuthService` is injected via `.environmentObject`
/// as a render-only stub — the init is `@MainActor`, so the test class
/// is marked `@MainActor` throughout to keep the call in-actor.
///
/// Tests cover:
/// - Light + dark mode of the full sheet (happy mood, name filled)
/// - Mood card selection states (cheer / calm selected, light)
/// - Save disabled state (empty name, light)
///
/// `record: .missing` auto-records baselines on first run.
/// CI overrides with `SNAPSHOT_TESTING_RECORD=never`.
@MainActor
final class RisoEditProfileSheetSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Full sheet — light + dark

    func testEditProfileSheetHappyLight() {
        let view = makeSheet(
            displayName: "OYBC User",
            email: "you@example.com",
            mood: .happy
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 660)),
            record: recordMode
        )
    }

    func testEditProfileSheetHappyDark() {
        let view = makeSheet(
            displayName: "OYBC User",
            email: "you@example.com",
            mood: .happy
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 660),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Mood selection variants

    func testEditProfileSheetCheerMoodLight() {
        let view = makeSheet(
            displayName: "OYBC User",
            email: "you@example.com",
            mood: .cheer
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 660)),
            record: recordMode
        )
    }

    func testEditProfileSheetCalmMoodLight() {
        let view = makeSheet(
            displayName: "OYBC User",
            email: "you@example.com",
            mood: .calm
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 660)),
            record: recordMode
        )
    }

    // MARK: - Save disabled (empty name)

    func testEditProfileSheetEmptyNameLight() {
        let view = makeSheet(
            displayName: "",
            email: "you@example.com",
            mood: .happy
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 660)),
            record: recordMode
        )
    }

    // MARK: - Helpers

    /// Wraps `EditProfileSheet` with a stub `AuthService` environment object.
    /// The sheet is presented directly (not inside a `.sheet` modifier) so
    /// the NavigationStack chrome renders in a fixed rect.
    private func makeSheet(
        displayName: String,
        email: String?,
        mood: BlipPlaceholder.Mood
    ) -> some View {
        EditProfileSheet(
            displayName: displayName,
            email: email,
            initialMood: mood,
            updateName: { _ in },
            onSave: {},
            onCancel: {}
        )
    }
}
