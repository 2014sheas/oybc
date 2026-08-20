import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for `RisoPoolRowEditorView` (Inline Task Editing PR 1) —
/// the inline pool-row editor leaf for simple & counting tasks.
///
/// Rendered at iPhone 16 width (393pt); iOS-version pinning is enforced at the
/// scheme level (see CLAUDE.md → Snapshot Testing).
final class PoolRowEditorSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func countingDraft() -> TaskEditPatch {
        var d = TaskEditPatch(title: "Run 5 km"); d.action = "Run"; d.goal = "5"; d.unit = "km"
        return d
    }

    private func host<V: View>(_ view: V, dark: Bool = false) -> some View {
        view
            .padding(20)
            .frame(width: 393)
            .background(Color.risoPaper)
            .environment(\.colorScheme, dark ? .dark : .light)
    }

    // MARK: - Counting editor

    func testCountingEditorLight() {
        let view = host(
            RisoPoolRowEditorView(
                taskType: .counting, draft: .constant(countingDraft()),
                onSave: {}, onDiscard: {}
            )
        )
        // +40 vs. the pre-rework baseline: the new "Title: {derived}" live
        // preview line (Bug #5 companion).
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 400)), record: recordMode)
    }

    func testCountingEditorDark() {
        let view = host(
            RisoPoolRowEditorView(
                taskType: .counting, draft: .constant(countingDraft()),
                onSave: {}, onDiscard: {}
            ),
            dark: true
        )
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 400)), record: recordMode)
    }

    // MARK: - Validation blocked (unit cleared → Save disabled + red line)

    func testCountingValidationBlockedLight() {
        var d = countingDraft(); d.unit = ""
        let view = host(
            RisoPoolRowEditorView(
                taskType: .counting, draft: .constant(d),
                onSave: {}, onDiscard: {}
            )
        )
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 420)), record: recordMode)
    }

    // MARK: - Compound editor

    private func compoundDraft() -> TaskEditPatch {
        var d = TaskEditPatch(title: "Morning routine")
        var progress = ChildPatch(id: "s2", childTaskId: "s2", title: "Run", isCounting: true)
        progress.action = "Run"; progress.goal = "3"; progress.unit = "km"
        d.children = [
            ChildPatch(id: "s1", childTaskId: "s1", title: "Make the bed", isCounting: false),
            progress,
        ]
        return d
    }

    func testCompoundEditorLight() {
        let view = host(
            RisoPoolRowEditorView(taskType: .compound, draft: .constant(compoundDraft()),
                                  onSave: {}, onDiscard: {})
        )
        // +80 vs. the pre-rework baseline: the new shared `RisoCompoundRulePicker`
        // (rule chips row) above the sub-tasks list.
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 640)), record: recordMode)
    }

    func testCompoundEditorDark() {
        let view = host(
            RisoPoolRowEditorView(taskType: .compound, draft: .constant(compoundDraft()),
                                  onSave: {}, onDiscard: {}),
            dark: true
        )
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 640)), record: recordMode)
    }

    /// Rule = At least N — proves the shared picker's conditional threshold
    /// stepper renders inside the inline editor exactly as it does in the
    /// create panel (`RisoCompoundPanelSnapshotTests.testCompoundAtLeastN*`).
    func testCompoundEditorAtLeastNLight() {
        var d = compoundDraft()
        d.operatorType = .mOfN
        d.threshold = 2
        let view = host(
            RisoPoolRowEditorView(taskType: .compound, draft: .constant(d),
                                  onSave: {}, onDiscard: {})
        )
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 680)), record: recordMode)
    }

    func testCompoundEditorAtLeastNDark() {
        var d = compoundDraft()
        d.operatorType = .mOfN
        d.threshold = 2
        let view = host(
            RisoPoolRowEditorView(taskType: .compound, draft: .constant(d),
                                  onSave: {}, onDiscard: {}),
            dark: true
        )
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 680)), record: recordMode)
    }

    // MARK: - Simple (normal) editor

    func testNormalEditorLight() {
        let view = host(
            RisoPoolRowEditorView(
                taskType: .normal, draft: .constant(TaskEditPatch(title: "Stretch")),
                onSave: {}, onDiscard: {}
            )
        )
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 260)), record: recordMode)
    }
}
