// Gated out post-compound-tasks-unification. The mock fixture passed
// `[CompositeTask]` to `CompositeWizardBuildStepView` whose signature
// changed to `[Task]`. Phase 8 will update + re-enable this harness.
#if false
#if DEBUG
import SwiftUI

/// Debug-only harness that mounts `CompositeWizardBuildStepView`
/// directly with mock data so we can screenshot the Build step without
/// driving the full wizard flow.
///
/// Activated by launching the simulator build with:
///   xcrun simctl launch <device> com.oybc.OYBC -previewCompositeBuild YES
///
/// Used to inspect layout/density/typography of the inline library
/// picker. It is NOT a flow or behavior test — `onToggleLibraryItem`,
/// `onAddInline`, `onBack`, and `onNext` are no-ops. The wrapped
/// `CompositeSubtaskList` is seeded with one existing-mode subtask so
/// the selections region has content. The library shows a handful of
/// tasks across all four types so the badge/search/filter affordances
/// are all exercisable.
///
/// Never compiled into Release builds.
struct CompositeBuildPreviewHarness: View {
    @StateObject private var subtaskList = Self.makeSeededList()
    @State private var threshold: Int = 2

    var body: some View {
        ScrollView {
            CompositeWizardBuildStepView(
                subtaskList: subtaskList,
                operatorType: .and,
                threshold: $threshold,
                libraryTasks: Self.mockTasks,
                libraryCompositeTasks: Self.mockComposites,
                taskBoardCounts: Self.mockBoardCounts,
                taskStepCounts: Self.mockStepCounts,
                compositeSubtaskCounts: Self.mockCompositeSubtaskCounts,
                compositeLeafPreviews: Self.mockCompositeLeafPreviews,
                onRemove: { _ in /* no-op */ },
                onToggleLibraryItem: { id, kind in
                    // Mirror the wizard's toggleLibraryItem semantics so
                    // the selections region stays in sync with the
                    // library checkmarks — otherwise tapping a row does
                    // nothing visible, which obscures the layout.
                    let alreadyIdx = subtaskList.items.firstIndex { item in
                        guard item.mode == .existing else { return false }
                        let existingId = item.selectionType == .task
                            ? item.selectedTaskId
                            : item.selectedCompositeId
                        return existingId == id
                    }
                    if alreadyIdx != nil {
                        subtaskList.remove { item in
                            guard item.mode == .existing else { return false }
                            let existingId = item.selectionType == .task
                                ? item.selectedTaskId
                                : item.selectedCompositeId
                            return existingId == id
                        }
                    } else {
                        let item = SubtaskItem(mode: .existing)
                        item.selectionType = kind
                        if kind == .task {
                            item.selectedTaskId = id
                        } else {
                            item.selectedCompositeId = id
                        }
                        subtaskList.append(item)
                    }
                },
                onAddInline: { /* no-op */ },
                onBack: { /* no-op */ },
                onNext: { /* no-op */ }
            )
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Mock data

    private static let now = "2026-04-22T12:00:00Z"

    private static let mockTasks: [OYBC.Task] = [
        OYBC.Task(
            id: "mock-meditate",
            userId: "debug-harness",
            title: "Meditate",
            type: .normal,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        ),
        OYBC.Task(
            id: "mock-run",
            userId: "debug-harness",
            title: "Morning cardio",
            type: .counting,
            action: "Run",
            unit: "km",
            maxCount: 5,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        ),
        OYBC.Task(
            id: "mock-study",
            userId: "debug-harness",
            title: "Study Spanish",
            type: .progress,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        ),
        OYBC.Task(
            id: "mock-read",
            userId: "debug-harness",
            title: "Read",
            type: .normal,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        ),
        OYBC.Task(
            id: "mock-water",
            userId: "debug-harness",
            title: "Drink water",
            type: .counting,
            action: "Drink",
            unit: "glasses",
            maxCount: 8,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        ),
    ]

    private static let mockComposites: [CompositeTask] = [
        CompositeTask(
            id: "mock-comp-weekly",
            userId: "debug-harness",
            title: "Weekly Essentials",
            description: nil,
            rootNodeId: "mock-root-weekly",
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        ),
    ]

    private static let mockBoardCounts: [String: Int] = [
        "mock-meditate": 3,
        "mock-run": 1,
        "mock-read": 0,
    ]

    private static let mockStepCounts: [String: Int] = [
        "mock-study": 4,
    ]

    private static let mockCompositeSubtaskCounts: [String: Int] = [
        "mock-comp-weekly": 3,
    ]

    private static let mockCompositeLeafPreviews: [String: CompositeLeafPreview] = [
        "mock-comp-weekly": CompositeLeafPreview(
            titles: ["Run 5km", "Meditate", "Read"],
            totalLeaves: 3
        ),
    ]

    private static func makeSeededList() -> CompositeSubtaskList {
        let list = CompositeSubtaskList()
        let seed = SubtaskItem(mode: .existing)
        seed.selectionType = .task
        seed.selectedTaskId = "mock-meditate"
        list.append(seed)
        return list
    }
}
#endif
#endif
