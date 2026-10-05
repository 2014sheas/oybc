import SwiftUI

/// PoolEditorBodyView — the pool editor's scrolling content, shaped like the
/// board wizard's Tasks step: NAME field → the wizard's resting task list
/// (`RisoPoolListView`, `surface: .pool`) with the inline row editor
/// (`RisoPoolRowEditorView`) → the unchanged ADD section (quick-add row +
/// special-type panel + library picker) → deck-preview line.
///
/// Leaf view over a `PoolEditorViewModel`; chrome (header / Save / Delete)
/// lives in `PoolEditorView`. Twin of web `PoolEditorBody`.
struct PoolEditorBodyView: View {

    @Bindable var vm: PoolEditorViewModel

    @State private var showLibraryPicker = false
    @State private var librarySearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            nameField
            tasksSection
            Text(vm.deckPreviewText())
                .font(.risoBody(12.5, .semibold)).foregroundStyle(Color.risoMuted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
                .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
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

    // MARK: - Tasks

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            RisoPoolListView(
                surface: .pool,
                selectedTaskIds: Set(vm.poolTaskIds),
                orderedTaskIds: vm.poolTaskIds,
                effectiveTaskById: vm.effectiveTaskById,
                effectiveChildrenByCompound: vm.effectiveChildrenByCompound,
                isRecurring: false,
                onRemove: { vm.remove($0) },
                onEdit: { vm.openEditor($0) },
                sharedCountByTaskId: vm.sharedCountByTaskId,
                editingTaskId: vm.editingTaskId,
                editor: { task in
                    AnyView(
                        RisoPoolRowEditorView(
                            taskId: task.id,
                            taskType: task.type,
                            draft: $vm.editDraft,
                            libraryTasks: vm.pickerLibraryTasks,
                            allLinks: vm.allLinks,
                            onSave: { vm.saveEdit() },
                            onDiscard: { vm.discardEdit() }
                        )
                    )
                }
            )
            .disabled(vm.busy)

            Text("ADD TASKS").font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
                .padding(.top, 4)

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

            libraryPickerToggle
            if showLibraryPicker { libraryPicker }
        }
    }

    // MARK: - Library picker (inline expand — NOT a modal sheet)

    private var libraryPickerToggle: some View {
        Button {
            showLibraryPicker.toggle()
        } label: {
            HStack {
                Text("Reuse a task from your library \(showLibraryPicker ? "▴" : "▾")")
                    .font(.risoHead(13, .bold)).foregroundStyle(Color.risoMuted)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: Riso.cardRadius)) // whole dashed row is the tap target
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
        }
        .buttonStyle(.plain)
        .disabled(vm.busy)
    }

    private var libraryPicker: some View {
        let results = vm.libraryResults(query: librarySearch)
        let trimmedSearch = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.risoMuted)
                TextField("Search your tasks…", text: $librarySearch)
                    .font(.risoBody(13, .regular)).foregroundStyle(Color.risoInk)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
            }
            .padding(10)

            Divider().background(Color.risoInk.opacity(0.08))

            if results.isEmpty {
                Text(trimmedSearch.isEmpty ? "Every library task is already in this pool." : "No matches.")
                    .font(.risoBody(12.5, .regular)).foregroundStyle(Color.risoMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(14)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(results, id: \.id) { task in
                            Button {
                                vm.add(task.id)
                            } label: {
                                HStack(spacing: 10) {
                                    RisoTypeBadge(kind: risoKind(task.type), style: .letterSquare)
                                    Text(task.title.isEmpty ? "(untitled task)" : task.title)
                                        .font(.risoBody(13.5, .semibold)).foregroundStyle(Color.risoInk)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "plus")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color.risoMuted)
                                }
                                .padding(.vertical, 10).padding(.horizontal, 14)
                                .contentShape(Rectangle()) // whole row is the tap target
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.busy)
                            Divider().background(Color.risoInk.opacity(0.08))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .background(Color.risoPaper)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
    }

    private func risoKind(_ type: TaskType) -> RisoTaskKind {
        switch type {
        case .normal: return .normal
        case .counting: return .counting
        case .compound: return .compound
        case .achievement: return .achievement
        }
    }
}
