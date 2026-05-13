import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Create tab landing surface.
///
/// CreateHubView in wizard mode is just `BoardWizardView` mounted
/// inline — the step views themselves are covered by
/// `BoardWizardTasksStepSnapshotTests` and `BoardWizardStepsSnapshotTests`,
/// so we only snapshot the hub mode here.
///
/// The hub mode's `.onAppear` queries production `AppDatabase.shared`
/// for drafts + library count. UIHostingController doesn't fire
/// onAppear during snapshot rendering, so the snapshot shows the
/// view's initial state — empty drafts, libraryCount=0 — which is a
/// valid render state in its own right.
final class CreateHubSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    func testHubLanding() {
        let view = CreateHubView(
            userId: SnapshotFixtures.userId,
            preferences: SnapshotFixtures.makeUserPreferences(),
            onBoardCompleted: nil
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }
}
