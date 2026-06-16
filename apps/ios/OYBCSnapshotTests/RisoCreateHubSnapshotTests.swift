import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the three Riso Create-hub design gaps:
///
/// 1. **CreateHubBoardCTAView** (both variants, both kinds) — rendered in
///    isolation since it takes only props.
/// 2. **CreateHubDraftsListView** — rendered with seeded draft rows so the
///    Riso draft-row styling is exercised.
/// 3. **BoardWizardCancelDialogView** — rendered in both the enabled and
///    disabled save states, and the delete-draft variant.
/// 4. **RisoPreviewGrid** — the private read-only grid extracted from
///    `BoardWizardPreviewStepView` is exercised indirectly by snapshotting
///    the full `BoardWizardPreviewStepView`. The grid itself is `private` so
///    it can only be reached through the parent.
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

    /// Primary one-off CTA — large Riso red card with gold icon.
    func testCTAOneOffPrimary() {
        let view = CreateHubBoardCTAView(kind: .oneOff, onTap: { }, variant: .primary)
            .padding(Riso.gutter)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 100), traits: lightTraits),
            record: recordMode
        )
    }

    func testCTAOneOffPrimaryDark() {
        let view = CreateHubBoardCTAView(kind: .oneOff, onTap: { }, variant: .primary)
            .padding(Riso.gutter)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 100), traits: darkTraits),
            record: recordMode
        )
    }

    /// Secondary one-off CTA — compact paper2 card.
    func testCTAOneOffSecondary() {
        let view = CreateHubBoardCTAView(kind: .oneOff, onTap: { }, variant: .secondary)
            .padding(Riso.gutter)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 80), traits: lightTraits),
            record: recordMode
        )
    }

    /// Secondary recurring CTA — compact card with repeat icon.
    func testCTARecurringSecondary() {
        let view = CreateHubBoardCTAView(kind: .recurring, onTap: { }, variant: .secondary)
            .padding(Riso.gutter)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 80), traits: lightTraits),
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
            SnapshotFixtures.makeBoard(id: "draft-a", name: "Weekly Wellness", boardSize: 5, status: .draft),
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

    // MARK: - 4. Wizard Preview Step (exercises RisoPreviewGrid)

    /// Full `BoardWizardPreviewStepView` — the private `RisoPreviewGrid` is
    /// exercised here since it's not accessible directly from tests.
    ///
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
