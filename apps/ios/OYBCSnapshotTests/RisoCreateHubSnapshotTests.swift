import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the three Riso Create-hub design gaps:
///
/// 1. **CreateHubBoardCTAView** (both `kind`s — Board Creation Split, iOS PR
///    A, replaced the single primary/secondary-variant CTA with two fixed-
///    mode cards) — rendered in isolation since it takes only props.
/// 2. **CreateHubDraftsListView** — rendered with seeded draft rows so the
///    Riso draft-row styling is exercised.
/// 3. **BoardWizardCancelDialogView** — rendered in both the enabled and
///    disabled save states, and the delete-draft variant.
/// 4. **BoardWizardPreviewStepView (Preview mode)** — the full step view in its
///    default Preview sub-mode, exercising the `RearrangeGrid` in display-only
///    mode alongside the toggle bar and summary card. Rearrange-mode coverage
///    is in `WizardArrangePreviewSnapshotTests`.
///
/// **Why not CreateHubView itself?**
/// `CreateHubView.hubContent` calls `pendingRecurringVM.reloadAsync()` and
/// `vm.reloadDrafts()` on `.onAppear`, which reach `AppDatabase.shared`. The
/// UIHostingController `.image` snapshot renderer does NOT fire `.onAppear`,
/// so the view renders in its initial-state (empty slots, empty drafts).
/// Snapshotting that initial state is tested by the existing
/// `CreateHubSnapshotTests.testHubLanding()` — we don't duplicate it here.
/// Instead we snapshot the prop-taking child components directly, which
/// gives higher-fidelity coverage of the Riso reskin without DB coupling.
final class RisoCreateHubSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private let lightTraits = UITraitCollection(userInterfaceStyle: .light)
    private let darkTraits  = UITraitCollection(userInterfaceStyle: .dark)

    // MARK: - 1. CreateHubBoardCTAView

    /// One-off CTA — full-width Riso RED card with gold icon.
    func testCTAOneOff() {
        let view = CreateHubBoardCTAView(kind: .oneOff, onTap: { })
            .padding(Riso.gutter)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 100), traits: lightTraits),
            record: recordMode
        )
    }

    func testCTAOneOffDark() {
        let view = CreateHubBoardCTAView(kind: .oneOff, onTap: { })
            .padding(Riso.gutter)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 100), traits: darkTraits),
            record: recordMode
        )
    }

    /// Recurring CTA — full-width Riso BLUE card with gold icon.
    func testCTARecurring() {
        let view = CreateHubBoardCTAView(kind: .recurring, onTap: { })
            .padding(Riso.gutter)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 100), traits: lightTraits),
            record: recordMode
        )
    }

    func testCTARecurringDark() {
        let view = CreateHubBoardCTAView(kind: .recurring, onTap: { })
            .padding(Riso.gutter)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 100), traits: darkTraits),
            record: recordMode
        )
    }

    // MARK: - 2. CreateHubDraftsListView

    /// Single-draft row list — verifies Riso row chrome + section label.
    func testDraftsListSingleRow() {
        let board = SnapshotFixtures.makeBoard(
            id: "draft-1",
            name: "April Reading Sprint",
            boardSize: 5,
            status: .draft
        )
        let drafts = [DraftRowData(board: board, taskCount: 12)]
        let view = CreateHubDraftsListView(
            drafts: drafts,
            onResume: { _ in },
            onDelete: { _ in }
        )
        .padding(Riso.gutter)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 110), traits: lightTraits),
            record: recordMode
        )
    }

    func testDraftsListSingleRowDark() {
        let board = SnapshotFixtures.makeBoard(
            id: "draft-1",
            name: "April Reading Sprint",
            boardSize: 5,
            status: .draft
        )
        let drafts = [DraftRowData(board: board, taskCount: 12)]
        let view = CreateHubDraftsListView(
            drafts: drafts,
            onResume: { _ in },
            onDelete: { _ in }
        )
        .padding(Riso.gutter)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 110), traits: darkTraits),
            record: recordMode
        )
    }

    /// Multi-draft list — verifies stacked rows, count pill.
    func testDraftsListMultipleRows() {
        let boards = [
            // Recurring draft — exercises the blue RECURRING pill + cadence meta line.
            SnapshotFixtures.makeBoard(id: "draft-a", name: "Weekly Wellness", boardSize: 5, timeframe: .weekly, status: .draft, isRecurringDraft: true),
            SnapshotFixtures.makeBoard(id: "draft-b", name: "", boardSize: 4, status: .draft),
            SnapshotFixtures.makeBoard(id: "draft-c", name: "Q2 Goals", boardSize: 3, status: .draft),
        ]
        let drafts = [
            DraftRowData(board: boards[0], taskCount: 24),
            DraftRowData(board: boards[1], taskCount: 0),
            DraftRowData(board: boards[2], taskCount: 7),
        ]
        let view = CreateHubDraftsListView(
            drafts: drafts,
            onResume: { _ in },
            onDelete: { _ in }
        )
        .padding(Riso.gutter)
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 230), traits: lightTraits),
            record: recordMode
        )
    }

    // MARK: - 3. BoardWizardCancelDialogView

    /// Resting state — both Save and Discard/Keep enabled.
    func testCancelDialogEnabled() {
        let view = BoardWizardCancelDialogView(
            canSaveDraft: true,
            saveDraftBlockedReason: nil,
            saveDraftLabel: "Save Draft",
            onSaveDraft: { },
            onDiscard: { },
            onKeepEditing: { }
        )
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 280), traits: lightTraits),
            record: recordMode
        )
    }

    func testCancelDialogEnabledDark() {
        let view = BoardWizardCancelDialogView(
            canSaveDraft: true,
            saveDraftBlockedReason: nil,
            saveDraftLabel: "Save Draft",
            onSaveDraft: { },
            onDiscard: { },
            onKeepEditing: { }
        )
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 280), traits: darkTraits),
            record: recordMode
        )
    }

    /// Disabled save — verifies muted button + blocked-reason text.
    func testCancelDialogSaveDisabled() {
        let view = BoardWizardCancelDialogView(
            canSaveDraft: false,
            saveDraftBlockedReason: "Board name is required to save as a draft.",
            saveDraftLabel: "Save Draft",
            onSaveDraft: { },
            onDiscard: { },
            onKeepEditing: { }
        )
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 310), traits: lightTraits),
            record: recordMode
        )
    }

    /// Resume-draft mode — shows the "Delete draft" button and "Save Changes" label.
    func testCancelDialogWithDeleteDraft() {
        let view = BoardWizardCancelDialogView(
            canSaveDraft: true,
            saveDraftBlockedReason: nil,
            saveDraftLabel: "Save Changes",
            onSaveDraft: { },
            onDiscard: { },
            onKeepEditing: { },
            onDeleteDraft: { }
        )
        .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 340), traits: lightTraits),
            record: recordMode
        )
    }

    // MARK: - 4. Wizard Preview Step (exercises RearrangeGrid in Preview mode)

    /// Full `BoardWizardPreviewStepView` in its default Preview sub-mode.
    /// Exercises `RearrangeGrid` (display-only), the toggle bar, and the summary card.
    /// Pinned date (2026-04-01) prevents month-rollover flakiness.
    func testPreviewStepWithRisoGrid() {
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

    func testPreviewStepWithRisoGridDark() {
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
}
