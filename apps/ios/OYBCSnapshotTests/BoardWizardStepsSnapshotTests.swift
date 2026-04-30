import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the wizard's Setup + Preview steps.
/// Tasks step has its own dedicated test file
/// (`BoardWizardTasksStepSnapshotTests`) since it carries the most
/// regression risk (rich library list, search, filter, context menus).
final class BoardWizardStepsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Setup step (Step 1)

    func testSetupStepBlank() {
        let controller = SnapshotFixtures.makeWizardController(stage: .setupBlank)
        let view = BoardWizardSetupStepView(
            controller: controller,
            onCancel: { },
            onNext: { }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    func testSetupStepValid() {
        let controller = SnapshotFixtures.makeWizardController(stage: .setupValid)
        let view = BoardWizardSetupStepView(
            controller: controller,
            onCancel: { },
            onNext: { }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    // MARK: - Preview step (Step 3)

    /// Preview-step fixture — fills the wizard out with selected tasks
    /// drawn from the dense library so the BingoBoard sub-render finds
    /// its source data.
    func testPreviewStepReady() {
        let library = SnapshotFixtures.makeTaskLibrary(state: .dense)
        let controller = SnapshotFixtures.makeWizardController(stage: .previewReady)
        let view = BoardWizardPreviewStepView(
            controller: controller,
            library: library,
            userId: SnapshotFixtures.userId,
            onBack: { },
            onComplete: { _, _ in }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 900)),
            record: recordMode
        )
    }
}
