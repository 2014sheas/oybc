import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the wizard Preview step's Phase 4 "Arrange" upgrade:
/// the `RearrangeGrid`-backed board, the Preview ⇄ Rearrange toggle, and the
/// optional Shuffle button.
///
/// Strategy:
///   - **Preview mode**: snapshot the full `BoardWizardPreviewStepView` at its
///     default initial state (`arrangeSubMode == .preview`, `rearrange == false`).
///     This gives a static, deterministic baseline of the grid in display-only mode.
///   - **Rearrange mode (static)**: snapshot a small prop-driven wrapper that renders
///     the same toggle bar + `RearrangeGrid` with `rearrange: false` for snapshot
///     determinism (jiggle is an animation, not a static state). Visual shape and
///     cell styling are fully exercised; the drag / tap / jiggle interactions are
///     exercised manually per the iOS testing convention.
///
/// All fixtures use `isRandomized = false` + a pinned reference date (2026-04-01)
/// so placement ordering and date labels are deterministic across runs.
///
/// COVERAGE NOTE (pre-WC audit, 2026-07-29): every fixture task here has
/// `isCompleted == false` and no `task_events`, so these snapshots CANNOT
/// distinguish windowed from lifetime completion — a regression that dropped
/// the preview's windowed resolution (PR #373's bug class) would still render
/// all-grey here. That regression is pinned by the logic suites instead:
/// `WizardPreviewCompletionTests.swift` (iOS) / `wizardPreviewWindowed.test.ts`
/// (web). Don't mistake a green run here for windowed-resolution coverage.
final class WizardArrangePreviewSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private let lightTraits = UITraitCollection(userInterfaceStyle: .light)
    private let darkTraits  = UITraitCollection(userInterfaceStyle: .dark)

    // MARK: - Preview mode (full step view)

    /// Full `BoardWizardPreviewStepView` in its default Preview sub-mode.
    /// Exercises the toggle (Preview selected), RearrangeGrid in display-only
    /// mode, and the summary card.
    func testPreviewModeLight() {
        let (view, _) = makeStepView()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 1000), traits: lightTraits),
            record: recordMode
        )
    }

    func testPreviewModeDark() {
        let (view, _) = makeStepView()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 1000), traits: darkTraits),
            record: recordMode
        )
    }

    // MARK: - Rearrange mode (static wrapper — rearrange: false for determinism)

    /// Control bar + RearrangeGrid in the visual shape of Rearrange mode, but
    /// with `rearrange: false` so no jiggle animation appears in the snapshot.
    /// Tests cell styling, the "Rearrange" segment being selected, and the hint line.
    func testRearrangeModeStaticLight() {
        let view = makeRearrangeWrapper(rearrange: false)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 560), traits: lightTraits),
            record: recordMode
        )
    }

    func testRearrangeModeStaticDark() {
        let view = makeRearrangeWrapper(rearrange: false)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 560), traits: darkTraits),
            record: recordMode
        )
    }

    // MARK: - View builders

    /// Returns a fully configured `BoardWizardPreviewStepView` in Preview mode
    /// (the default), plus the library used so callers can extend coverage if needed.
    private func makeStepView() -> (BoardWizardPreviewStepView, TaskLibraryViewModel) {
        let library = SnapshotFixtures.makeTaskLibrary(state: .dense)
        let controller = SnapshotFixtures.makeWizardController(stage: .previewReady)
        let view = BoardWizardPreviewStepView(
            controller: controller,
            library: library,
            userId: SnapshotFixtures.userId,
            onBack: { },
            onComplete: { _, _ in }
        )
        return (view, library)
    }

    /// A self-contained wrapper that renders the arrange control bar and a
    /// `RearrangeGrid` in the visual state of Rearrange mode. `rearrange`
    /// controls the grid's jiggle+gesture flag — pass `false` for static snapshots.
    private func makeRearrangeWrapper(rearrange: Bool) -> some View {
        let library = SnapshotFixtures.makeTaskLibrary(state: .dense)
        let controller = SnapshotFixtures.makeWizardController(stage: .previewReady)
        // Build the same cells that `BoardWizardPreviewStepView.wizardCells` produces.
        let placement = buildWizardPlacement(controller: controller, library: library)
        let (cells, taskMap) = buildArrangeCells(
            placement: placement,
            size: controller.size,
            centerType: controller.centerType
        )

        return ZStack {
            Color.risoPaper.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                // Control bar — toggle (Rearrange selected) + no Shuffle
                // (isRandomized = false in snapshot fixtures → canShuffle = false).
                HStack(spacing: 8) {
                    // Show the bar with "Rearrange" visually active.
                    arrangeBarFixture(selectedMode: .rearrange)
                }
                .padding(.horizontal, Riso.gutter)

                // Rearrange hint line
                Text("Drag to rearrange · tap two squares to swap")
                    .font(.risoBody(12, .regular))
                    .foregroundStyle(Color.risoMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Riso.gutter)

                // Grid — sideLength hardcoded to snapshot width (393pt) minus gutters.
                let side = CGFloat(393) - 2 * Riso.gutter
                // Grid
                RearrangeGrid(
                    cells: cells,
                    gridSize: controller.size,
                    taskMap: taskMap,
                    centerSquareType: controller.centerType,
                    centerCustomName: controller.centerCustomName,
                    rearrange: rearrange,
                    sideLength: side,
                    onReorder: { _ in }  // no-op for snapshot
                )
                .padding(.horizontal, Riso.gutter)
            }
            .padding(.vertical, 24)
        }
    }

    /// Renders a static representation of the toggle bar with the given mode
    /// appearing selected. Uses `RisoSegmented`'s color contract: selected
    /// segment gets blue fill + cream text; unselected gets paper2 + ink text.
    private func arrangeBarFixture(selectedMode: ArrangeSubMode) -> some View {
        // Build a static toggle using the same `RisoSegmented` component.
        // We can't bind `$arrangeSubMode` from a fixture, so we render the
        // appearance by passing a @State-bound value from a tiny wrapper.
        _ToggleBarWrapper(selectedMode: selectedMode)
    }

    // MARK: - Cell builder (mirrors BoardWizardPreviewStepView.wizardCells)

    /// Produces `(cells, taskMap)` from a wizard placement array, using the same
    /// logic as `BoardWizardPreviewStepView.wizardCells` / `.wizardTaskMap`.
    private func buildArrangeCells(
        placement: WizardPlacement,
        size: Int,
        centerType: CenterSquareType
    ) -> ([RearrangeCellData], [String: Task]) {
        let isOdd = size % 2 != 0
        let centerIdx = isOdd ? (size / 2) * size + (size / 2) : -1
        var cells: [RearrangeCellData] = []
        var taskMap: [String: Task] = [:]

        for (i, task) in placement.enumerated() {
            let row = i / size
            let col = i % size
            let isPinnedCenter = isOdd && i == centerIdx && centerType != .none

            if isPinnedCenter, task == nil {
                cells.append(RearrangeCellData(
                    id: "center", taskId: nil,
                    isCenter: true, isEmpty: false,
                    originalRow: row, originalCol: col
                ))
            } else if let task = task {
                if taskMap[task.id] == nil { taskMap[task.id] = task }
                cells.append(RearrangeCellData(
                    id: isPinnedCenter ? "center" : task.id,
                    taskId: task.id,
                    isCenter: isPinnedCenter, isEmpty: false,
                    originalRow: row, originalCol: col
                ))
            } else {
                cells.append(RearrangeCellData(
                    id: "empty-\(row)-\(col)", taskId: nil,
                    isCenter: false, isEmpty: true,
                    originalRow: row, originalCol: col
                ))
            }
        }
        return (cells, taskMap)
    }
}

// MARK: - _ToggleBarWrapper

/// Internal SwiftUI helper used only by `WizardArrangePreviewSnapshotTests`.
/// Renders a `RisoSegmented` toggle initialized to a given mode so the
/// snapshot captures the correct visual state (selected vs unselected segments).
private struct _ToggleBarWrapper: View {
    let selectedMode: ArrangeSubMode
    @State private var mode: ArrangeSubMode

    init(selectedMode: ArrangeSubMode) {
        self.selectedMode = selectedMode
        _mode = State(initialValue: selectedMode)
    }

    var body: some View {
        RisoSegmented(
            options: [
                (value: ArrangeSubMode.preview,   label: "Preview"),
                (value: ArrangeSubMode.rearrange, label: "Rearrange"),
            ],
            selection: $mode
        )
    }
}
