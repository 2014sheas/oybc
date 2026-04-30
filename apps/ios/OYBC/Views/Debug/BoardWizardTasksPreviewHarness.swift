// Gated out post-compound-tasks-unification. The mock fixture used legacy
// CompositeNode + TaskStep + the gated `BoardTask.makePlayground` factory.
// Phase 8 will rebuild this harness with `compoundChildren` mocks.
#if false
#if DEBUG
import SwiftUI

/// Debug-only harness that mounts `BoardWizardTasksStepView` directly
/// with mock data, same pattern as `CompositeBuildPreviewHarness`.
///
/// Activated by launching with:
///   xcrun simctl launch <device> com.oybc.OYBC -previewBoardTasks YES
///
/// Used to inspect the row layout, usage hints, and composite-expand
/// behavior on a real iPhone viewport without needing real credentials
/// or tapping through the wizard. Never compiled into Release.
struct BoardWizardTasksPreviewHarness: View {
    @State private var library = Self.seedLibrary()
    @State private var selectedIds: Set<String> = ["mock-meditate"]
    @State private var centerTaskId: String? = nil

    var body: some View {
        ScrollView {
            BoardWizardTasksStepView(
                library: library,
                selectedTaskIds: $selectedIds,
                tasksRequired: 8,
                centerTaskMode: false,
                centerTaskId: $centerTaskId,
                userId: "debug-harness",
                onTaskCreated: { _, _, _ in },
                onCompositeCreated: { _ in },
                onLibraryReloadRequested: { },
                onBack: { },
                onNext: { }
            )
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Mock data

    private static let now = "2026-04-22T12:00:00Z"

    private static func seedLibrary() -> TaskLibraryViewModel {
        let vm = TaskLibraryViewModel()
        vm.libraryTasks = mockTasks
        vm.libraryCompositeTasks = mockComposites
        vm.allLibraryTaskSteps = mockSteps
        vm.allLibraryBoardTasks = mockBoardTasks
        vm.allLibraryCompositeNodes = mockCompositeNodes
        return vm
    }

    private static let mockTasks: [OYBC.Task] = [
        OYBC.Task(
            id: "mock-meditate",
            userId: "debug-harness",
            title: "Meditate",
            type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        ),
        OYBC.Task(
            id: "mock-run",
            userId: "debug-harness",
            title: "Morning cardio",
            type: .counting,
            action: "Run", unit: "km", maxCount: 5,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        ),
        OYBC.Task(
            id: "mock-study",
            userId: "debug-harness",
            title: "Study Spanish",
            type: .progress,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        ),
        OYBC.Task(
            id: "mock-read",
            userId: "debug-harness",
            title: "Read",
            type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        ),
    ]

    private static let mockComposites: [CompositeTask] = [
        CompositeTask(
            id: "mock-comp-morning",
            userId: "debug-harness",
            title: "Morning Routine",
            description: nil,
            rootNodeId: "mock-root-morning",
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        ),
    ]

    private static let mockSteps: [TaskStep] = [
        TaskStep(
            id: "step-1", taskId: "mock-study", stepIndex: 0,
            title: "Lesson 1", type: .normal,
            action: nil, unit: nil, maxCount: nil, linkedTaskId: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        ),
        TaskStep(
            id: "step-2", taskId: "mock-study", stepIndex: 1,
            title: "Lesson 2", type: .normal,
            action: nil, unit: nil, maxCount: nil, linkedTaskId: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        ),
        TaskStep(
            id: "step-3", taskId: "mock-study", stepIndex: 2,
            title: "Lesson 3", type: .normal,
            action: nil, unit: nil, maxCount: nil, linkedTaskId: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        ),
        TaskStep(
            id: "step-4", taskId: "mock-study", stepIndex: 3,
            title: "Lesson 4", type: .normal,
            action: nil, unit: nil, maxCount: nil, linkedTaskId: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        ),
    ]

    // BoardTask has a custom `init(from:)` so the memberwise init isn't
    // synthesised — use the existing playground factory instead.
    private static let mockBoardTasks: [BoardTask] = [
        // Meditate on 3 distinct boards
        BoardTask.makePlayground(boardId: "b-1", taskId: "mock-meditate", row: 0, col: 0, now: now),
        BoardTask.makePlayground(boardId: "b-2", taskId: "mock-meditate", row: 0, col: 0, now: now),
        BoardTask.makePlayground(boardId: "b-3", taskId: "mock-meditate", row: 0, col: 0, now: now),
        // Morning cardio on 1 board
        BoardTask.makePlayground(boardId: "b-1", taskId: "mock-run", row: 0, col: 1, now: now),
    ]

    private static let mockCompositeNodes: [CompositeNode] = [
        CompositeNode(
            id: "mock-root-morning",
            compositeTaskId: "mock-comp-morning",
            parentNodeId: nil,
            nodeIndex: 0,
            nodeType: .operator,
            operatorType: .and,
            threshold: nil,
            taskId: nil,
            childCompositeTaskId: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        ),
        CompositeNode(
            id: "mock-leaf-1",
            compositeTaskId: "mock-comp-morning",
            parentNodeId: "mock-root-morning",
            nodeIndex: 0,
            nodeType: .leaf,
            operatorType: nil,
            threshold: nil,
            taskId: "mock-meditate",
            childCompositeTaskId: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        ),
        CompositeNode(
            id: "mock-leaf-2",
            compositeTaskId: "mock-comp-morning",
            parentNodeId: "mock-root-morning",
            nodeIndex: 1,
            nodeType: .leaf,
            operatorType: nil,
            threshold: nil,
            taskId: "mock-run",
            childCompositeTaskId: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        ),
    ]
}
#endif
#endif
