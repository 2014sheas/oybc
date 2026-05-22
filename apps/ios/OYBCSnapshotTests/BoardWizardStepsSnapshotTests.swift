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

    /// Setup step in recurring-template mode (#71 — the "Create a
    /// recurring board" entry). Verifies the cadence card "Every week /
    /// Starting: Week of …" renders and Custom is absent from the
    /// timeframe selector. The core-board variant is covered by
    /// `RecurringBoardsSnapshotTests/testSetupStepCoreBoard`.
    func testSetupStepRecurring() {
        let controller = SnapshotFixtures.makeWizardController(stage: .setupRecurring)
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

    /// Preview step with `isRecurring=true`. Verifies the Timeframe row
    /// shows "Every week · starting Week of …" (instead of the bare
    /// window label, which would be indistinguishable from a one-off
    /// board for that week) and the Recurring summary row appears.
    /// Closes the gap left by `e3e2b63` + `d7f5f9c` — neither commit had
    /// a Preview-step snapshot for the recurring path.
    func testPreviewStepRecurring() {
        let library = SnapshotFixtures.makeTaskLibrary(state: .dense)
        let controller = SnapshotFixtures.makeWizardController(stage: .previewRecurring)
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
