import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the wizard's Setup + Preview steps (Riso reskin).
///
/// Tasks step has its own dedicated test file
/// (`BoardWizardTasksStepSnapshotTests`) since it carries the most
/// regression risk (rich library list, search, filter, context menus).
///
/// **Determinism note**: all fixtures pass a pinned `targetWindowDate`
/// (2026-04-01) so `computedBoundaries` / `timeframeDisplayLabel` resolve
/// to a stable calendar window regardless of when the tests run. This prevents
/// month-rollover flakiness in the Riso date-note cards. See
/// `SnapshotFixtures.fixedReferenceDate`.
final class BoardWizardStepsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private let lightTraits = UITraitCollection(userInterfaceStyle: .light)
    private let darkTraits  = UITraitCollection(userInterfaceStyle: .dark)

    // MARK: - Setup step (Step 1) — light

    func testSetupStepBlank() {
        let controller = SnapshotFixtures.makeWizardController(stage: .setupBlank)
        let view = BoardWizardSetupStepView(
            controller: controller,
            onCancel: { },
            onNext: { }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700), traits: lightTraits),
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
            as: .image(layout: .fixed(width: 393, height: 700), traits: lightTraits),
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
            as: .image(layout: .fixed(width: 393, height: 700), traits: lightTraits),
            record: recordMode
        )
    }

    /// Setup step with the Ongoing (indefinite) timeframe selected. Verifies
    /// the "Ongoing" segment renders and the dashed "No end date" note replaces
    /// the window caption / custom date pickers.
    func testSetupStepIndefinite() {
        let controller = SnapshotFixtures.makeWizardController(stage: .setupIndefinite)
        let view = BoardWizardSetupStepView(
            controller: controller,
            onCancel: { },
            onNext: { }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700), traits: lightTraits),
            record: recordMode
        )
    }

    // MARK: - Setup step — dark

    func testSetupStepBlankDark() {
        let controller = SnapshotFixtures.makeWizardController(stage: .setupBlank)
        let view = BoardWizardSetupStepView(
            controller: controller,
            onCancel: { },
            onNext: { }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700), traits: darkTraits),
            record: recordMode
        )
    }

    func testSetupStepValidDark() {
        let controller = SnapshotFixtures.makeWizardController(stage: .setupValid)
        let view = BoardWizardSetupStepView(
            controller: controller,
            onCancel: { },
            onNext: { }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700), traits: darkTraits),
            record: recordMode
        )
    }

    func testSetupStepIndefiniteDark() {
        let controller = SnapshotFixtures.makeWizardController(stage: .setupIndefinite)
        let view = BoardWizardSetupStepView(
            controller: controller,
            onCancel: { },
            onNext: { }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700), traits: darkTraits),
            record: recordMode
        )
    }

    func testSetupStepRecurringDark() {
        let controller = SnapshotFixtures.makeWizardController(stage: .setupRecurring)
        let view = BoardWizardSetupStepView(
            controller: controller,
            onCancel: { },
            onNext: { }
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700), traits: darkTraits),
            record: recordMode
        )
    }

    // MARK: - Preview step (Step 3) — light

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
            as: .image(layout: .fixed(width: 393, height: 900), traits: lightTraits),
            record: recordMode
        )
    }

    /// Preview step with `isRecurring=true`. Verifies the Timeframe row
    /// shows "Every week · starting Week of …" (instead of the bare
    /// window label, which would be indistinguishable from a one-off
    /// board for that week) and the Recurring summary row appears.
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
            as: .image(layout: .fixed(width: 393, height: 900), traits: lightTraits),
            record: recordMode
        )
    }

    // MARK: - Preview step — dark

    func testPreviewStepReadyDark() {
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
            as: .image(layout: .fixed(width: 393, height: 900), traits: darkTraits),
            record: recordMode
        )
    }

    func testPreviewStepRecurringDark() {
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
            as: .image(layout: .fixed(width: 393, height: 900), traits: darkTraits),
            record: recordMode
        )
    }
}
