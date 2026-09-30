import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `HelpView` (Profile reorg PR1, new).
///
/// `HelpView` only depends on `@EnvironmentObject TutorialProgressStore`,
/// which — unlike `AuthService` — has no Firebase dependency and is safe to
/// construct directly in a test host. So unlike `SettingsSnapshotTests`
/// (which reconstructs statically to dodge `AuthService`), this hosts the
/// REAL `HelpView` with a real `TutorialProgressStore` seeded via
/// `UserDefaults(suiteName:)` to control `completedCount`/`isComplete`
/// without touching the shared `.standard` suite other tests might read.
///
/// `record: .missing` auto-records baselines on the first run.
/// CI overrides with `SNAPSHOT_TESTING_RECORD=never`.
final class HelpSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    /// Builds an isolated `TutorialProgressStore` backed by its own
    /// `UserDefaults` suite (cleared first) so each test's completed-count
    /// is deterministic and independent of any other test's state.
    private func makeStore(completed: Int) -> TutorialProgressStore {
        let suiteName = "HelpSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = TutorialProgressStore(defaults: defaults)
        for lesson in tutorialLessons.prefix(completed) {
            store.markLearned(lesson.id)
        }
        return store
    }

    private func helpView(completed: Int) -> some View {
        NavigationStack {
            HelpView()
                .environmentObject(makeStore(completed: completed))
        }
    }

    // MARK: - In progress (3/8)

    func testInProgressLight() {
        assertSnapshot(
            of: helpView(completed: 3),
            as: .image(layout: .fixed(width: 393, height: 500)),
            record: recordMode
        )
    }

    func testInProgressDark() {
        assertSnapshot(
            of: helpView(completed: 3),
            as: .image(
                layout: .fixed(width: 393, height: 500),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Complete (8/8 — "Replay tutorial")

    func testCompleteLight() {
        assertSnapshot(
            of: helpView(completed: TutorialProgressStore.totalLessons),
            as: .image(layout: .fixed(width: 393, height: 500)),
            record: recordMode
        )
    }

    func testCompleteDark() {
        assertSnapshot(
            of: helpView(completed: TutorialProgressStore.totalLessons),
            as: .image(
                layout: .fixed(width: 393, height: 500),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }
}
