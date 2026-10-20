import SwiftUI

// MARK: - SquareMenuCellTarget

/// Which square's tap-menu (`.confirmationDialog`, i4/d1) is open. `id`
/// matches `SquareEditCellData.id`; `cellKey` is its CURRENT "row-col" slot
/// — the key every `viewModel.handleEdit*` mutator takes.
struct SquareMenuCellTarget: Identifiable, Equatable {
    let id: String
    let cellKey: String
    let isCenter: Bool
    let isEmpty: Bool
}

// MARK: - SquarePickerRouteTarget

/// Drives the `SquarePickerSheetView` (D13) from either a tap on an empty
/// (non-center) square, or a menu action (Replace / "Add a task…" on an
/// empty center).
struct SquarePickerRouteTarget: Identifiable {
    var id: String { cellKey }
    let cellKey: String
    let mode: SquarePickerMode
}

// MARK: - BoardEditPresenter

/// Attaches the square tap-menu, the Square picker sheet, the Edit-task
/// sheet, and the Save-failure / Board-closed alerts to `BoardPlayView`
/// (Board Edit redesign slice 3, T5) — the squares-editor counterpart to
/// slice 2's `BoardActionsPresenter`. The discard ("Cancel with unsaved
/// changes") confirm stays inline in `BoardEditPanel` — it needs no
/// database access and is purely a Cancel-button concern.
struct BoardEditPresenter: ViewModifier {
    @ObservedObject var viewModel: BoardPlayViewModel
    let userId: String
    /// The user's full task library — filtered per-picker-open via
    /// `SquarePickerCandidates`.
    let allTasks: [Task]
    @Binding var editMode: Bool
    @Binding var editSaving: Bool
    @Binding var squareMenuTarget: SquareMenuCellTarget?
    @Binding var pickerTarget: SquarePickerRouteTarget?
    /// Fired after a successful squares Save — the caller shows its own
    /// "Board saved" toast (shared with Archive / Details / Repeat saves).
    let onSaved: () -> Void

    @State private var taskEditTarget: EditModeTaskTarget? = nil
    @State private var editSaveError: String? = nil
    @State private var boardClosedMessage: String? = nil

    // Getting Started hooks — inert outside a lesson. A lesson's tap-menu
    // offers "Replace task…" alone; the other items stay visible but off.
    @Environment(\.tutorialCoach) private var tutorialCoach
    @Environment(\.tutorialSignals) private var tutorialSignals

    // MARK: - Title

    private var menuTitle: String {
        guard let target = squareMenuTarget else { return "Square" }
        if target.isCenter, viewModel.editCenterType == .free { return "Free space" }
        guard let draft = viewModel.editSquaresDraft[target.cellKey] else {
            return target.isEmpty || target.isCenter ? "Empty square" : "Square"
        }
        return viewModel.editDraftTaskMap[draft.taskId]?.title ?? "Square"
    }

    func body(content: Content) -> some View {
        content
            // Occupied / center square tap-menu (D16, i4/d1).
            .confirmationDialog(
                menuTitle,
                isPresented: Binding(
                    get: { squareMenuTarget != nil },
                    set: { if !$0 { squareMenuTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: squareMenuTarget
            ) { target in
                menuActions(for: target)
            }
            // Square picker (D13) — Replace, or "Add a task…" on an empty
            // center. A tap on an empty NON-center square routes straight
            // here without the menu (see `BoardPlayView.handleSquareTap`).
            .sheet(item: $pickerTarget) { target in
                SquarePickerSheetView(
                    mode: target.mode,
                    userId: userId,
                    candidateTasks: candidateTasks(for: target.mode),
                    counterRootTasks: allTasks,
                    onDismiss: { pickerTarget = nil },
                    onConfirm: { taskId, pending, placement in
                        switch target.mode {
                        case .add:
                            viewModel.handleEditAdd(cellKey: target.cellKey, taskId: taskId, pending: pending, placement: placement)
                        case .replace:
                            viewModel.handleEditReplace(cellKey: target.cellKey, taskId: taskId, pending: pending, placement: placement)
                            tutorialCoach?.handle(.squareSwapped)
                        }
                        pickerTarget = nil
                    },
                    timeframe: viewModel.board?.timeframe,
                    startDate: viewModel.board?.startDate,
                    endDate: viewModel.board?.endDate
                )
            }
            // Edit-task sheet (i6, unchanged from slice 2).
            .sheet(item: $taskEditTarget) { target in taskEditSheet(for: target) }
            .alert(
                "Couldn’t save",
                isPresented: Binding(
                    get: { editSaveError != nil },
                    set: { if !$0 { editSaveError = nil } }
                ),
                actions: { Button("OK", role: .cancel) { editSaveError = nil } },
                message: { Text(editSaveError ?? "") }
            )
            .alert(
                "Board closed",
                isPresented: Binding(
                    get: { boardClosedMessage != nil },
                    set: { if !$0 { boardClosedMessage = nil } }
                ),
                actions: {
                    Button("OK", role: .cancel) {
                        boardClosedMessage = nil
                        withAnimation(.easeInOut(duration: 0.22)) { editMode = false }
                    }
                },
                message: { Text(boardClosedMessage ?? "") }
            )
            .onChange(of: viewModel.editEvent) { _, event in
                guard let event else { return }
                switch event.outcome {
                case .saved:
                    editSaving = false
                    withAnimation(.easeInOut(duration: 0.22)) { editMode = false }
                    onSaved()
                case .saveFailed(let message):
                    editSaving = false
                    editSaveError = message
                case .boardClosed(let message):
                    editSaving = false
                    boardClosedMessage = message
                }
            }
    }

    // MARK: - Menu content

    @ViewBuilder
    private func menuActions(for target: SquareMenuCellTarget) -> some View {
        if let draft = viewModel.editSquaresDraft[target.cellKey] {
            Button("Replace task…") {
                pickerTarget = SquarePickerRouteTarget(
                    cellKey: target.cellKey, mode: .replace(currentTaskId: draft.taskId)
                )
            }
            Button("Edit task…") {
                if let task = viewModel.editDraftTaskMap[draft.taskId] {
                    taskEditTarget = EditModeTaskTarget(id: target.cellKey, task: task)
                }
            }
            .disabled(tutorialSignals.active)
            Button(viewModel.isEditCellLocked(cellKey: target.cellKey) ? "Unlock" : "Lock in place") {
                viewModel.handleEditToggleLock(cellKey: target.cellKey)
            }
            .disabled(tutorialSignals.active)
            Button("Remove from board", role: .destructive) {
                viewModel.handleEditRemove(cellKey: target.cellKey)
            }
            .disabled(tutorialSignals.active)
            // The positional center can ALSO free itself even while occupied.
            if target.isCenter {
                Button("Make it a free space") { viewModel.handleEditCenterFree() }
                    .disabled(tutorialSignals.active)
            }
        } else if target.isCenter {
            if viewModel.editCenterType == .free {
                Button("Make it a task square") { viewModel.handleEditCenterTask() }
                    .disabled(tutorialSignals.active)
            } else {
                // Empty NONE center (OQ5).
                Button("Add a task…") {
                    pickerTarget = SquarePickerRouteTarget(cellKey: target.cellKey, mode: .add)
                }
                .disabled(tutorialSignals.active)
                Button("Make it a free space") { viewModel.handleEditCenterFree() }
                    .disabled(tutorialSignals.active)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - Edit-task compound inputs

    /// The task as stored (or as its pending payload holds it) — before any
    /// staged "Edit task…" override. `target.task` is override-merged.
    private func originalTask(for merged: Task) -> Task {
        if let pending = viewModel.editSquaresDraft.values.compactMap(\.pending).first(where: { $0.task.id == merged.id }) {
            return pending.task
        }
        return viewModel.taskMap[merged.id] ?? merged
    }

    /// A still-pending (picker-born, not yet saved) compound's ordered
    /// sub-tasks, read from its staged payload — they are not in the DB, so
    /// the sheet is seeded synchronously. nil for every other task.
    private func pendingCompoundChildren(for task: Task) -> [Task]? {
        guard task.type == .compound,
              let payload = viewModel.editSquaresDraft.values.compactMap(\.pending).first(where: { $0.task.id == task.id })
        else { return nil }
        let byId = Dictionary(payload.childTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return payload.childLinks.sorted { $0.childIndex < $1.childIndex }.compactMap { byId[$0.childTaskId] }
    }

    /// Loader for the edit sheet's compound inputs (sub-tasks of an existing
    /// compound + the quick-add row's library/links), read through the view
    /// model's injected database off the main actor. nil for an achievement
    /// (no compound editor).
    private func compoundInputsLoader(for task: Task, hasStagedCompound: Bool) -> (() async -> SquareEditTaskSheet.CompoundInputs)? {
        guard task.type != .achievement else { return nil }
        let database = viewModel.database
        let needsChildren = task.type == .compound && !hasStagedCompound && pendingCompoundChildren(for: task) == nil
        let taskId = task.id
        let userId = task.userId
        // Slice 3a: existing children seed at this square's per-child goals.
        let childTargets = viewModel.boardTasks.first { $0.taskId == taskId }?.childTargets
        return {
            await _Concurrency.Task.detached(priority: .userInitiated) {
                var inputs = SquareEditTaskSheet.CompoundInputs(children: nil, libraryTasks: [], allLinks: [])
                if needsChildren {
                    do {
                        inputs.children = try database.fetchCompoundChildrenTasks(parentTaskId: taskId)
                            .map { PlacementParams.withChildTarget($0, childTargets: childTargets) }
                    } catch {
                        inputs.childrenError = "Couldn’t load sub-tasks: \(error.localizedDescription)"
                    }
                }
                do {
                    let library = try database.fetchCompoundPickerInputs(userId: userId)
                    inputs.libraryTasks = library.libraryTasks
                    inputs.allLinks = library.allLinks
                    inputs.allTasks = library.allTasks
                } catch {
                    inputs.libraryLoaded = false
                }
                return inputs
            }.value
        }
    }

    /// The Board Edit task sheet for `target` (its own function so the
    /// type-checker handles the long initialiser).
    @ViewBuilder
    private func taskEditSheet(for target: EditModeTaskTarget) -> some View {
            let original = originalTask(for: target.task)
            let staged = viewModel.editTaskOverrides[target.task.id]?.compound
            let forkCheck = viewModel.database.boardScopedForkCheck(taskId: target.task.id, boardId: viewModel.boardId)
            SquareEditTaskSheet(
                task: target.task,
                original: original,
                stagedCompound: staged,
                compoundChildren: staged == nil ? pendingCompoundChildren(for: original) : nil,
                goalWindow: boardGoalWindow,
                libraryInputsState: .loading,
                loadInputs: compoundInputsLoader(for: original, hasStagedCompound: staged != nil),
                database: viewModel.database,
                forkingTaskIds: forkCheck.forking,
                forkBaselineRows: forkCheck.rows,
                forkConfirmed: viewModel.editForkConfirmed,
                onForkConfirmed: { viewModel.editForkConfirmed = true },
                onDone: { patch in
                    taskEditTarget = nil
                    viewModel.handleEditTaskOverride(taskId: target.task.id, patch: patch)
                },
                onCancel: { taskEditTarget = nil }
            )
            .tutorialExitGuard()
    }

    /// The board's window for a counter picked as a compound sub-task.
    private var boardGoalWindow: CounterPlacement.PickWindow? {
        guard let board = viewModel.board else { return nil }
        return CounterPlacement.PickWindow(timeframe: board.timeframe, startDate: board.startDate, endDate: board.endDate)
    }

    // MARK: - Candidates

    private func candidateTasks(for mode: SquarePickerMode) -> [Task] {
        let currentTaskId: String? = {
            if case .replace(let id) = mode { return id }
            return nil
        }()
        let placedTaskIds = Set(viewModel.editSquaresDraft.values.map { $0.taskId })
        return SquarePickerCandidates.filter(SquarePickerCandidates.Input(
            candidateTasks: allTasks,
            currentTaskId: currentTaskId,
            placedTaskIds: placedTaskIds,
            counterFamilyByTaskId: BoardSources.buildCounterFamilyMap(allTasks)
        ))
    }
}
