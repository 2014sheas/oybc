import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for `BoardWizardTasksStepView` — the wizard step that
/// motivated this whole harness (the doubled-padding bug lived here).
///
/// Render variants:
///   - empty library (the empty-state UI)
///   - dense library, nothing selected
///   - dense library, several rows selected (selection-active tint)
///   - center-task mode active (star affordance shows on selected rows)
///
/// Each test is wrapped in `UIHostingController` and rendered at iPhone
/// 17 Pro width (393pt) — pinning the device frame keeps diffs stable
/// across machines. iOS-version pinning is enforced at the scheme level
/// (see CLAUDE.md → Snapshot Testing).
final class BoardWizardTasksStepSnapshotTests: XCTestCase {

    /// Flip to `true` and run once after a UI change to refresh
    /// baselines. Leave `false` for normal CI / verification runs so
    /// diffs cause assertion failures instead of silent overwrites.
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Variants

    func testEmptyLibrary() {
        let view = makeView(libraryState: .empty)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testDenseLibraryUnselected() {
        let view = makeView(libraryState: .dense)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testDenseLibrarySomeSelected() {
        let view = makeView(
            libraryState: .dense,
            initialSelection: ["t-normal-1", "t-counting-1", "t-compound-and"]
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testDenseLibraryCenterTaskMode() {
        let view = makeView(
            libraryState: .dense,
            initialSelection: ["t-normal-1", "t-counting-1"],
            centerTaskMode: true,
            initialCenterTaskId: "t-normal-1"
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    // MARK: - Builder

    /// Constructs a `BoardWizardTasksStepView` with stable bindings so
    /// the snapshotted hierarchy matches what users see in production
    /// without coupling to live wizard state.
    private func makeView(
        libraryState: SnapshotFixtures.LibraryState,
        initialSelection: Set<String> = [],
        centerTaskMode: Bool = false,
        initialCenterTaskId: String? = nil
    ) -> some View {
        let library = SnapshotFixtures.makeTaskLibrary(state: libraryState)
        let host = TasksStepHost(
            library: library,
            initialSelection: initialSelection,
            initialCenterTaskId: initialCenterTaskId,
            centerTaskMode: centerTaskMode
        )
        return host
    }
}

/// Wraps `BoardWizardTasksStepView` in a parent that owns the @State
/// values it binds to. Snapshot tests render this host so the bindings
/// resolve without going through `BoardWizardView`.
private struct TasksStepHost: View {
    let library: TaskLibraryViewModel
    @State var selectedTaskIds: Set<String>
    @State var centerTaskId: String?
    let centerTaskMode: Bool

    init(
        library: TaskLibraryViewModel,
        initialSelection: Set<String>,
        initialCenterTaskId: String?,
        centerTaskMode: Bool
    ) {
        self.library = library
        self._selectedTaskIds = State(initialValue: initialSelection)
        self._centerTaskId = State(initialValue: initialCenterTaskId)
        self.centerTaskMode = centerTaskMode
    }

    var body: some View {
        BoardWizardTasksStepView(
            library: library,
            selectedTaskIds: $selectedTaskIds,
            tasksRequired: 25,
            centerTaskMode: centerTaskMode,
            centerTaskId: $centerTaskId,
            userId: SnapshotFixtures.userId,
            // Snapshot fixture: .custom hides the new "From parent boards"
            // filter chip (no parent timeframes), keeping baselines stable.
            currentTimeframe: .custom,
            onTaskCreated: { _, _, _ in },
            onCompositeCreated: { _ in },
            onLibraryReloadRequested: { },
            onBack: { },
            onNext: { }
        )
    }
}
