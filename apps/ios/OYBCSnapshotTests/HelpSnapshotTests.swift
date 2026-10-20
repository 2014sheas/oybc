import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `HelpView` (Profile reorg PR1, new; counts to 9 since
/// the tutorial board rework). Hosts the REAL `HelpView` with a preview
/// `TutorialCoordinator` (no database) seeded with the progress to show.
///
/// `record: .missing` auto-records baselines on the first run.
/// CI overrides with `SNAPSHOT_TESTING_RECORD=never`.
@MainActor
final class HelpSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func progress(done: Int) -> TutorialProgress {
        var p = TutorialProgress.empty
        for id in TutorialLessonID.allCases.prefix(done) { p.set(id, .done) }
        return p
    }

    private func helpView(done: Int) -> some View {
        NavigationStack {
            HelpView()
                .environmentObject(TutorialCoordinator.preview(progress: progress(done: done)))
        }
    }

    // MARK: - Not started (0/9)

    func testNotStartedLight() {
        assertSnapshot(of: helpView(done: 0), as: .image(layout: .fixed(width: 393, height: 500)), record: recordMode)
    }

    // MARK: - In progress (3/9)

    func testInProgressLight() {
        assertSnapshot(of: helpView(done: 3), as: .image(layout: .fixed(width: 393, height: 500)), record: recordMode)
    }

    func testInProgressDark() {
        assertSnapshot(
            of: helpView(done: 3),
            as: .image(layout: .fixed(width: 393, height: 500), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Complete (9/9) — the button still opens the board

    func testCompleteLight() {
        assertSnapshot(of: helpView(done: 9), as: .image(layout: .fixed(width: 393, height: 500)), record: recordMode)
    }
}
