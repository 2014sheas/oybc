import SwiftUI

/// Task detail — the route pushed from the Tasks tab (and Counter Detail's unit-task rows).
/// A thin shell: `TaskDetailViewModel` owns the data and writes, `TaskDetailHost` the sheets,
/// `TaskDetailScreen` the pixels. iOS twin of web's `TaskDetailPage.tsx`.
struct TaskDetailView: View {
    let taskId: String
    let userId: String
    let onChanged: () -> Void
    let onDeleted: () -> Void
    /// Cross-tab navigation: a board row switches to the Boards tab and pushes that board.
    let onOpenBoard: (String) -> Void
    /// Opens Counter detail (pushed on the caller's stack — Tasks tab).
    var onOpenCounter: (String) -> Void = { _ in }
    /// Injected database (ROADMAP B3 seam); defaults to the app singleton.
    var database: AppDatabase = .shared

    @StateObject private var vm: TaskDetailViewModel
    @State private var tab: TaskDetailTab = .all
    /// In-detail navigation: a parent chip / child row pushes another detail.
    @State private var openedTaskId: TaskIdItem?
    @Environment(\.dismiss) private var dismiss

    init(
        taskId: String, userId: String, onChanged: @escaping () -> Void, onDeleted: @escaping () -> Void,
        onOpenBoard: @escaping (String) -> Void, onOpenCounter: @escaping (String) -> Void = { _ in },
        database: AppDatabase = .shared
    ) {
        self.taskId = taskId
        self.userId = userId
        self.onChanged = onChanged
        self.onDeleted = onDeleted
        self.onOpenBoard = onOpenBoard
        self.onOpenCounter = onOpenCounter
        self.database = database
        _vm = StateObject(wrappedValue: TaskDetailViewModel(taskId: taskId, database: database))
    }

    var body: some View {
        TaskDetailHost(
            vm: vm, taskId: taskId, presentation: .route, tab: $tab,
            onBack: { dismiss() },
            onOpenTask: { openedTaskId = TaskIdItem(id: $0) },
            onOpenCounter: onOpenCounter, onOpenBoard: onOpenBoard,
            onChanged: onChanged, onDeleted: onDeleted
        )
        .toolbar(.hidden, for: .navigationBar)
        .background(InteractivePopEnabler()) // swipe-back survives the hidden bar
        .navigationDestination(item: $openedTaskId) { item in
            TaskDetailView(
                taskId: item.id, userId: userId, onChanged: onChanged,
                onDeleted: { openedTaskId = nil; onChanged() }, // a deleted child pops its page
                onOpenBoard: onOpenBoard, onOpenCounter: onOpenCounter, database: database
            )
        }
    }
}
