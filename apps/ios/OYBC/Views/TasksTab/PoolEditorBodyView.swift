import SwiftUI

/// PoolEditorBodyView — the pool editor's scrolling content, shaped like the
/// board wizard's Tasks step: NAME field → pool header card (count / deck
/// floor / deck-preview note) → "Add tasks" (quick-add row — typing also finds
/// library tasks to reuse — + special-type panel) → the task list (`RisoPoolListView`,
/// `surface: .pool`) with the inline row editor (`RisoPoolRowEditorView`).
///
/// Leaf view over a `PoolEditorViewModel`; chrome (header / Save / Delete)
/// lives in `PoolEditorView`. Twin of web `PoolEditorBody`.
struct PoolEditorBodyView: View {

    @Bindable var vm: PoolEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            nameField
            headerCard
            tasksSection
            if let errorMessage = vm.errorMessage {
                Text(errorMessage)
                    .font(.risoBody(13, .semibold)).foregroundStyle(Color.risoRed)
            }
        }
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAME").font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
            RisoTextField(placeholder: "e.g. \"Evening wind-down\"", text: $vm.name)
                .disabled(vm.busy)
        }
    }

    // MARK: - Header card (wizard's pool header, deck-preview inputs)

    private var headerCard: some View {
        let h = vm.headerInputs()
        return RisoTasksPoolHeaderView(
            capacity: h.count,
            tasksRequired: h.required,
            isRecurring: false,
            centerTaskMode: false,
            centerSatisfied: false,
            noteOverride: h.note
        )
    }

    // MARK: - Tasks

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add tasks").risoSectionLabel()

            // Polling quick-add row (owner decision 2026-07-21). Immediate
            // persist (`onPendingCreated: nil`) — a pool is not a wizard draft.
            VStack(spacing: 0) {
                RisoQuickAddRowView(
                    userId: vm.userId,
                    defaultStartDate: nil,
                    defaultEndDate: nil,
                    onTaskCreated: { taskId, _, _ in vm.add(taskId) },
                    onPendingCreated: nil,
                    onLibraryReloadRequested: { vm.library.loadLibrary(userId: vm.userId) },
                    libraryTasks: vm.poolableBrowsableTasks,
                    counterRootTasks: vm.library.libraryTasks,
                    selectedIds: Set(vm.poolTaskIds),
                    onExistingTaskPicked: { vm.add($0.id) }
                )
            }
            .padding(12)
            .risoCard(fill: .risoPaper2)
            .risoHardShadow(Riso.Shadow.small)
            .disabled(vm.busy)

            // Same inline special-type panel the board wizard's Tasks step uses.
            RisoSpecialTaskPanel(
                userId: vm.userId,
                defaultStartDate: nil,
                defaultEndDate: nil,
                taskLibrary: vm.poolableBrowsableTasks,
                suggestionPool: vm.library.libraryTasks,
                onTaskCreated: { taskId, _, _ in vm.add(taskId) },
                onCompoundCreated: { vm.add($0.id) },
                onPendingCreated: nil,
                onLibraryReloadRequested: { vm.library.loadLibrary(userId: vm.userId) },
                allowAchievement: false,
                submitLabel: "Add to pool ✦"
            )
            .disabled(vm.busy)

            RisoPoolListView(
                surface: .pool,
                selectedTaskIds: Set(vm.selectedTasks.map(\.id)),
                orderedTaskIds: vm.poolTaskIds,
                effectiveTaskById: vm.effectiveTaskById,
                effectiveChildrenByCompound: vm.effectiveChildrenByCompound,
                isRecurring: false,
                onRemove: { vm.remove($0) },
                onEdit: { vm.openEditor($0) },
                editingTaskId: vm.editingTaskId,
                editor: { task in
                    AnyView(
                        RisoPoolRowEditorView(
                            task: task,
                            draft: $vm.editDraft,
                            libraryTasks: vm.pickerLibraryTasks,
                            counterRootTasks: vm.pickerAllTasks,
                            allLinks: vm.allLinks,
                            onSave: { vm.saveEdit() },
                            onDiscard: { vm.discardEdit() }
                        )
                    )
                },
                manualTaskVary: vm.memberVary,
                onSetManualVary: { vm.setMemberVary(taskId: $0, level: $1) }
            )
            .disabled(vm.busy)
        }
    }
}
