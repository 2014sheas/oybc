import SwiftUI

/// Source-board grid for the wizard's `From a board…` filter.
/// Renders the chosen source board at its real geometry; each square
/// is a tap target. Tap = Link the underlying Task into the new
/// board's selection. Long-press = `.contextMenu` reusing existing
/// `BoardWizardTasksStepView` vocabulary.
///
/// iOS twin of web's `FromBoardGrid`. Visual states are color/border
/// only (blue tint = linked, amber tint = copied, 35% opacity =
/// expired, orange border = source's center square).
struct FromBoardGridView: View {
    @Bindable var vm: SourceBoardsViewModel

    /// Source board to browse. The parent looks this up from
    /// `vm.eligibleBoards` so the grid can render geometry + header
    /// without re-fetching.
    let sourceBoard: Board
    let userId: String

    /// Tasks already linked into the new board's selection (any source).
    let selectedTaskIds: Set<String>
    /// Tasks copied this session — amber tint indicator.
    let copiedTaskIds: Set<String>

    /// Toggle Link/Unlink for the underlying Task.
    let onToggleSelection: (String) -> Void
    /// Open the Copy sheet for `⎘ Add a copy of this task…`.
    let onCopyTask: (OYBC.Task) -> Void
    /// Auto-add every non-deleted leaf of a compound.
    let onAddAllSubtasks: (OYBC.Task) -> Void
    /// `↗ Open in library` — surfaces the task in TaskDetailSheet.
    let onOpenInLibrary: (String) -> Void
    /// Tap the source header `▾` to return to the picker.
    let onChangeSource: () -> Void
    /// Fired after a derived counter saves; parent auto-adds the id
    /// to selection.
    let onTaskCreated: (OYBC.Task) -> Void

    /// `Derive smaller version…` modal state — host-owned because the
    /// modal is presentational.
    @State private var derivingFromTask: OYBC.Task?
    @State private var deriveMaxCountInput: String = ""
    @State private var deriveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if vm.placements.isEmpty {
                Text("Nothing to add from this board.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                gridBody
            }
        }
        .onAppear {
            vm.loadPlacementsAsync(forBoardId: sourceBoard.id)
        }
        .onChange(of: sourceBoard.id) { _, newId in
            vm.loadPlacementsAsync(forBoardId: newId)
        }
        .sheet(item: $derivingFromTask) { source in
            DeriveCounterSheet(
                source: source,
                input: $deriveMaxCountInput,
                error: $deriveError,
                onCancel: { derivingFromTask = nil },
                onSave: { handleDeriveSave(source: source) }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            onChangeSource()
        } label: {
            HStack(spacing: 6) {
                Text("Source:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text(sourceBoard.name.isEmpty ? "Untitled board" : sourceBoard.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Text("▾")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private var gridBody: some View {
        let size = sourceBoard.boardSize
        let columns: [GridItem] = Array(
            repeating: GridItem(.flexible(), spacing: 6),
            count: size
        )
        // Map (row, col) → SourceBoardPlacement so empty cells render
        // as inert placeholders. Avoids reshuffling the layout when
        // the source board has gaps.
        var cells: [SourceBoardPlacement?] = Array(repeating: nil, count: size * size)
        for placement in vm.placements {
            let idx = placement.placement.row * size + placement.placement.col
            if idx >= 0 && idx < cells.count {
                cells[idx] = placement
            }
        }

        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<cells.count, id: \.self) { i in
                cellView(entry: cells[i])
            }
        }
        .padding(4)
    }

    @ViewBuilder
    private func cellView(entry: SourceBoardPlacement?) -> some View {
        if let entry, let task = entry.task {
            sourceCell(task: task, placement: entry.placement)
        } else {
            Rectangle()
                .fill(Color.clear)
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            Color.white.opacity(0.06),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                )
        }
    }

    @ViewBuilder
    private func sourceCell(task: OYBC.Task, placement: BoardTask) -> some View {
        let isSelected = selectedTaskIds.contains(task.id)
        let isCopied = copiedTaskIds.contains(task.id)
        let expired = TasksTabViewModel.isTaskExpired(task)
        let isCenter = placement.isCenter
        let bg: Color = {
            if isSelected { return .blue.opacity(0.22) }
            if isCopied { return .orange.opacity(0.18) }
            return Color.white.opacity(0.04)
        }()
        let borderColor: Color = {
            if isCenter { return .orange }
            if isSelected { return .blue.opacity(0.5) }
            if isCopied { return .orange.opacity(0.45) }
            return Color.white.opacity(0.08)
        }()
        let borderWidth: CGFloat = isCenter ? 2 : 1

        Button {
            if expired { return }
            onToggleSelection(task.id)
        } label: {
            ZStack(alignment: .bottom) {
                VStack(spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if expired {
                    Text("expired")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.secondary, lineWidth: 1)
                        )
                        .padding(.bottom, 4)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .opacity(expired ? 0.35 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(expired)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu {
            menuItems(for: task)
        }
    }

    @ViewBuilder
    private func menuItems(for task: OYBC.Task) -> some View {
        let isSelected = selectedTaskIds.contains(task.id)
        let isCompound = task.type == .compound
        let isCountingTemplate = task.type == .counting
            && task.action != nil
            && task.unit != nil
            && task.maxCount != nil

        Button(
            isSelected ? "Remove from board" : "Add to board (link)",
            systemImage: isSelected ? "minus.circle" : "plus.circle"
        ) {
            onToggleSelection(task.id)
        }
        Button(
            "Add a copy of this task…",
            systemImage: "doc.on.doc"
        ) {
            onCopyTask(task)
        }
        if isCountingTemplate {
            Button("Derive smaller version…", systemImage: "scalemass") {
                derivingFromTask = task
                deriveMaxCountInput = ""
                deriveError = nil
            }
        }
        if isCompound {
            Button("Add all subtasks to board", systemImage: "square.stack.3d.up") {
                onAddAllSubtasks(task)
            }
        }
        Button("Open in library", systemImage: "info.circle") {
            onOpenInLibrary(task.id)
        }
    }

    // MARK: - Derive save

    private func handleDeriveSave(source: OYBC.Task) {
        guard let action = source.action,
              let unit = source.unit,
              let parsed = Int(deriveMaxCountInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0
        else {
            deriveError = "Max count must be a positive integer"
            return
        }

        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "\(trimmedAction) \(parsed) \(trimmedUnit)"
        let now = AppDatabase.currentTimestamp()
        let newId = AppDatabase.generateUUID()

        let newTask = OYBC.Task(
            id: newId,
            userId: userId,
            title: title,
            description: nil,
            type: .counting,
            action: trimmedAction,
            unit: trimmedUnit,
            maxCount: parsed,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        )

        derivingFromTask = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.write { db in
                    try newTask.save(db)
                    try SyncQueueBuilder.makeItem(
                        entityType: "tasks",
                        entityId: newId,
                        operationType: .create,
                        payload: newTask,
                        now: now
                    ).save(db)
                }
                DispatchQueue.main.async {
                    onTaskCreated(newTask)
                }
            } catch {
                // Swallow on background — same pattern as the wizard list's
                // derive flow. The user can retry.
            }
        }
    }
}

// MARK: - Derive sheet

/// Minimal `Derive smaller version…` sheet for the source-board grid.
/// Mirrors the same flow as the wizard list view's inline derive
/// experience (`BoardWizardTasksStepView.deriveCounterSheet`) but
/// scoped to this grid so the two surfaces don't have to share state.
private struct DeriveCounterSheet: View {
    let source: OYBC.Task
    @Binding var input: String
    @Binding var error: String?
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        let action = (source.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = (source.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let preview = parsed > 0 ? "\(action) \(parsed) \(unit)" : nil

        NavigationStack {
            Form {
                Section("From") {
                    if let max = source.maxCount {
                        Text("\(source.title) — \(action) \(max) \(unit)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        Text(source.title)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Section("New max count") {
                    TextField("e.g. 20", text: $input)
                        .keyboardType(.numberPad)
                    if let preview {
                        Text("New title: \(preview)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Derive smaller version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
