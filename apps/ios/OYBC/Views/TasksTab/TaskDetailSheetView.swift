import SwiftUI

/// The "Open in library" sheet: the same Task Detail content with a grabber, a Done pill
/// grouped with ⋯ and no back chevron. In-sheet navigation REPLACES the content; once
/// swapped, a return pill (the previous task's letter + name) takes the chevron slot.
/// Counter Detail pushes inside the sheet's own stack. iOS twin of web's `TaskDetailSheet.tsx`.
struct TaskDetailSheetView: View {

    @State private var currentTaskId: String
    /// The tasks an in-sheet swap came from, oldest first — the return pill pops it.
    @State private var returnStack: [TaskDetailPresentation.ReturnTarget] = []
    /// The selected section survives in-sheet task swaps.
    @State private var tab: TaskDetailTab = .all
    @State private var openedCounterId: String?
    @StateObject private var vm: TaskDetailViewModel

    let onClose: () -> Void
    /// A board row: the presenter dismisses this sheet AND routes to the board. The board
    /// the sheet was opened from (`originBoardId`) just dismisses.
    let onOpenBoard: (String) -> Void
    var originBoardId: String? = nil
    let database: AppDatabase

    init(
        taskId: String,
        onClose: @escaping () -> Void,
        onOpenBoard: @escaping (String) -> Void,
        originBoardId: String? = nil,
        database: AppDatabase = .shared
    ) {
        _currentTaskId = State(initialValue: taskId)
        _vm = StateObject(wrappedValue: TaskDetailViewModel(taskId: taskId, database: database))
        self.onClose = onClose
        self.onOpenBoard = onOpenBoard
        self.originBoardId = originBoardId
        self.database = database
    }

    var body: some View {
        NavigationStack {
            TaskDetailHost(
                vm: vm, taskId: currentTaskId, presentation: .sheet(returnTo: returnStack.last), tab: $tab,
                onDone: onClose,
                onReturn: {
                    guard let previous = returnStack.popLast() else { return }
                    currentTaskId = previous.taskId
                },
                onOpenTask: { id in
                    if let model = vm.model {
                        returnStack.append(.init(taskId: currentTaskId, title: model.title, kind: model.kind))
                    }
                    currentTaskId = id
                },
                onOpenCounter: { openedCounterId = $0 },
                onOpenBoard: { id in
                    if id == originBoardId { onClose() } else { onOpenBoard(id) }
                },
                onDeleted: onClose
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openedCounterId) { counterId in
                CounterDetailView(counterId: counterId, showExpired: false, onOpenBoard: onOpenBoard)
            }
            // Counter detail can delete / unlink the counter; refresh when it pops back here.
            .onChange(of: openedCounterId) { _, newValue in
                if newValue == nil { _Concurrency.Task { await vm.refresh() } }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
