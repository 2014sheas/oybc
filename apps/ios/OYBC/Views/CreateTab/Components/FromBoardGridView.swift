import SwiftUI

/// Source-board grid for the wizard's `From a board…` filter.
/// Renders the chosen source board at its real geometry; each square
/// is a tap target. Tap = Link the underlying Task into the new
/// board's selection. Long-press = `.contextMenu` reusing existing
/// `BoardWizardTasksStepView` vocabulary.
///
/// Presentation-only reskin of the pre-Riso implementation. All
/// logic, callbacks, and data flow are preserved unchanged.
///
/// Visual states (color/border only):
/// - linked → gold fill + thick ink keyline
/// - copied  → green fill + ink keyline
/// - center (source)  → ink fill + gold border
/// - expired → 35% opacity
/// - resting → paper2 fill + dense keyline
///
/// iOS twin of web's `FromBoardGrid`.
struct FromBoardGridView: View {
    @Bindable var vm: SourceBoardsViewModel

    /// Source board to browse. The parent looks this up from
    /// `vm.eligibleBoards` so the grid can render geometry + header
    /// without re-fetching.
    let sourceBoard: Board
    let userId: String

    /// Tasks already linked into the new board's selection (any source).
    let selectedTaskIds: Set<String>
    /// Tasks copied this session — green tint indicator.
    let copiedTaskIds: Set<String>

    /// Toggle Link/Unlink for the underlying Task.
    let onToggleSelection: (String) -> Void
    /// Open the Copy sheet for `⎘ Add a copy of this task…`.
    let onCopyTask: (OYBC.Task) -> Void
    /// Auto-add every non-deleted leaf of a compound. Grid passes the
    /// already-resolved leaf ids so the parent doesn't have to re-look-
    /// up via its own library — the source's compound may have children
    /// outside the wizard's library.
    let onAddAllSubtasks: (OYBC.Task, [String]) -> Void
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
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
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
            RisoDeriveCounterSheet(
                source: source,
                input: $deriveMaxCountInput,
                error: $deriveError,
                userId: userId,
                onCancel: { derivingFromTask = nil },
                onSave: { handleDeriveSave(source: source) }
            )
        }
    }

    // MARK: - Header

    /// Tappable breadcrumb: "Source: <Board Name> ▾" — returns to picker.
    private var header: some View {
        Button {
            onChangeSource()
        } label: {
            HStack(spacing: 6) {
                Text("SOURCE:")
                    .font(.risoBody(11, .bold))
                    .tracking(0.22 * 11)
                    .foregroundStyle(Color.risoMuted)
                Text(sourceBoard.name.isEmpty ? "Untitled board" : sourceBoard.name)
                    .font(.risoHead(13.5, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.risoPaper2)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private var gridBody: some View {
        let size = sourceBoard.boardSize
        let columns: [GridItem] = Array(
            repeating: GridItem(.flexible(), spacing: Riso.cellGap),
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
        // FREE boards have NO BoardTask placement at the geometric center —
        // without a special case here the source grid would render a dashed
        // hole where the play view shows the FREE square. Mirror
        // BoardPlayView's behavior.
        let usesFreeCenter = size % 2 == 1 && sourceBoard.centerSquareType == .free
        let freeCenterIndex: Int = usesFreeCenter
            ? (size / 2) * size + (size / 2)
            : -1
        let freeCenterText: String = usesFreeCenter
            ? CenterSquare.getCenterDisplayText(type: sourceBoard.centerSquareType)
            : ""

        return LazyVGrid(columns: columns, spacing: Riso.cellGap) {
            ForEach(0..<cells.count, id: \.self) { i in
                cellView(
                    entry: cells[i],
                    isVirtualFreeCenter: i == freeCenterIndex && cells[i] == nil,
                    freeCenterText: freeCenterText
                )
            }
        }
        .padding(4)
    }

    @ViewBuilder
    private func cellView(
        entry: SourceBoardPlacement?,
        isVirtualFreeCenter: Bool,
        freeCenterText: String
    ) -> some View {
        if let entry, let task = entry.task {
            sourceCell(task: task, placement: entry.placement)
        } else if isVirtualFreeCenter {
            // Virtual FREE center — non-interactive, no BoardTask to link or
            // copy. Riso: ink fill with gold star/text.
            freeCenterCell(label: freeCenterText)
        } else {
            // Empty grid slot — dashed ink placeholder.
            emptyCell
        }
    }

    // MARK: - Cell variants

    /// Ink-black FREE center cell — mirrors `RisoBoardPlayCell.centerCellContent`.
    @ViewBuilder
    private func freeCenterCell(label: String) -> some View {
        VStack(spacing: 2) {
            StarShape()
                .fill(Color.risoGold)
                .frame(width: 11, height: 11)
            Text(label)
                .font(.risoHead(8, .extraBold))
                .tracking(0.5)
                .foregroundStyle(Color.risoGold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        // Non-inverting ink so the gold star/label stays legible in dark mode —
        // adaptive `risoInk` would flip to cream (adaptive-ink-fill trap).
        .background(Color.risoInkStatic)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cellRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
        )
        .accessibilityLabel(label)
    }

    /// Dashed empty-slot placeholder.
    private var emptyCell: some View {
        Rectangle()
            .fill(Color.clear)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .strokeBorder(
                        Color.risoInk.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
            )
    }

    /// Source board task cell — handles linked / copied / expired / center states.
    @ViewBuilder
    private func sourceCell(task: OYBC.Task, placement: BoardTask) -> some View {
        let isSelected = selectedTaskIds.contains(task.id)
        let isCopied = copiedTaskIds.contains(task.id)
        let expired = TasksTabViewModel.isTaskExpired(task)
        let isCenter = placement.isCenter

        // Background fill — priority: linked (gold) > copied (green) > center (ink) > resting
        let bg: Color = {
            if isCenter { return Color.risoInk }
            if isSelected { return Color.risoGold.opacity(0.25) }
            if isCopied { return Color.risoGreen.opacity(0.18) }
            return Color.risoPaper2
        }()

        // Keyline color and width
        let borderColor: Color = {
            if isCenter { return Color.risoGold }
            if isSelected { return Color.risoInk }
            if isCopied { return Color.risoGreen }
            return Color.risoInk
        }()
        let borderWidth: CGFloat = (isCenter || isSelected) ? Riso.Keyline.container : Riso.Keyline.dense

        // Text color — cream on dark fills, ink on light fills
        let textColor: Color = isCenter ? Color.risoGold : Color.risoInk

        Button {
            if expired { return }
            onToggleSelection(task.id)
        } label: {
            ZStack(alignment: .bottom) {
                ZStack(alignment: .topTrailing) {
                    // Title label
                    Text(task.title)
                        .font(.risoBody(9, .bold))
                        .tracking(-0.09)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(textColor)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Gold check top-right when linked
                    if isSelected && !isCenter {
                        ZStack {
                            Circle()
                                .fill(Color.risoGold)
                                .frame(width: 13, height: 13)
                            Circle()
                                .strokeBorder(Color.risoInk, lineWidth: 1.5)
                                .frame(width: 13, height: 13)
                            Image(systemName: "checkmark")
                                .font(.system(size: 6, weight: .black))
                                .foregroundStyle(Color.risoInk)
                        }
                        .padding(.top, 3)
                        .padding(.trailing, 3)
                    }
                }

                // "Expired" tag at bottom
                if expired {
                    Text("EXPIRED")
                        .font(.risoHead(7, .bold))
                        .foregroundStyle(Color.risoMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.risoPaper)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.risoMuted, lineWidth: 1)
                        )
                        .padding(.bottom, 3)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cellRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cellRadius)
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

    // MARK: - Context menu (logic unchanged)

    @ViewBuilder
    private func menuItems(for task: OYBC.Task) -> some View {
        let isSelected = selectedTaskIds.contains(task.id)
        let isCompound = task.type == .compound
        let isCountingTemplate = task.type == .counting
            && task.action != nil
            && task.unit != nil
            && task.maxCount != nil
        // Source-board-derived leaves (precomputed by the VM in the
        // same transaction that read the placements). Used both to
        // gate the menu item (hide when the compound has no leaves —
        // matches web's `leaves.length > 0`) and to pass through to
        // the parent's auto-add closure.
        let compoundLeafIds = isCompound
            ? (vm.compoundLeafIdsByParent[task.id] ?? [])
            : []

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
        if isCompound && !compoundLeafIds.isEmpty {
            Button("Add all subtasks to board", systemImage: "square.stack.3d.up") {
                onAddAllSubtasks(task, compoundLeafIds)
            }
        }
        Button("Open in library", systemImage: "info.circle") {
            onOpenInLibrary(task.id)
        }
    }

    // MARK: - Derive save

    /// R1 counters refresh — "Derive smaller version…" must produce a
    /// LINKED task, not a standalone duplicate (the sheet's own copy
    /// promises "same counter, lower goal" / "still counts {noun}"). See
    /// `resolveDeriveLinkTarget` for the source-resolution rule. Unlike
    /// `RisoLibrarySheetView` (which has a synchronous task map from the
    /// wizard's library), this grid only has the source BOARD's placements
    /// in memory, so the root task is fetched by id when `source` is
    /// itself derived.
    private func handleDeriveSave(source: OYBC.Task) {
        guard let action = source.action,
              let unit = source.unit,
              let parsed = Int(deriveMaxCountInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0
        else {
            deriveError = "Goal must be a positive integer"
            return
        }

        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = TaskTitle.generateCounterTaskTitle(action: trimmedAction, maxCount: parsed, unit: trimmedUnit)
        let now = AppDatabase.currentTimestamp()
        let newId = AppDatabase.generateUUID()

        // Keep the sheet open until the write either succeeds or fails
        // visibly. Mirrors the web grid's `onSave`.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rootId = source.sharedCounterId ?? source.id
                let rootTask = rootId == source.id ? source : try AppDatabase.shared.fetchTask(id: rootId)
                let linkTarget = resolveDeriveLinkTarget(source: source, rootTask: rootTask)

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
                    isDeleted: false,
                    sharedCounterId: linkTarget.sharedCounterId,
                    baseline: linkTarget.baseline
                )

                try AppDatabase.shared.createTaskAndEnqueue(newTask, now: now)
                DispatchQueue.main.async {
                    derivingFromTask = nil
                    deriveError = nil
                    onTaskCreated(newTask)
                }
            } catch {
                DispatchQueue.main.async {
                    deriveError = "Failed to save: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Riso derive counter sheet

/// Riso-styled `Derive smaller version…` sheet for the source-board grid.
/// Replaces the legacy `DeriveCounterSheet` (Form-based) with the
/// Riso design language. Logic is identical to the original.
private struct RisoDeriveCounterSheet: View {
    let source: OYBC.Task
    @Binding var input: String
    @Binding var error: String?
    let userId: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        let action = (source.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = (source.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let derivedTitle = parsed > 0 ? TaskTitle.generateCounterTaskTitle(action: action, maxCount: parsed, unit: unit) : nil

        NavigationStack {
            ZStack {
                RisoPaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // From section — "From {title} — same counter, lower goal."
                        VStack(alignment: .leading, spacing: 6) {
                            Text("DERIVED FROM")
                                .font(.risoBody(11, .bold))
                                .tracking(0.22 * 11)
                                .foregroundStyle(Color.risoMuted)
                            (Text("From ")
                                .font(.risoBody(13, .semibold))
                                .foregroundStyle(Color.risoMuted)
                            + Text(source.title)
                                .font(.risoHead(13, .bold))
                                .foregroundStyle(Color.risoInk)
                            + Text(" — same counter, lower goal.")
                                .font(.risoBody(13, .semibold))
                                .foregroundStyle(Color.risoMuted))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.risoPaper2)
                            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Riso.cardRadius)
                                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                            )
                        }

                        // New goal section
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NEW GOAL")
                                .font(.risoBody(11, .bold))
                                .tracking(0.22 * 11)
                                .foregroundStyle(Color.risoMuted)
                            RisoNumberField(placeholder: "e.g. 20", text: $input)
                        }

                        // Preview row — "New task: {derived title} — still counts {noun}."
                        if let derivedTitle {
                            (Text("New task: ")
                                .font(.risoBody(12, .regular))
                                .foregroundStyle(Color.risoMuted)
                            + Text(derivedTitle)
                                .font(.risoHead(13, .bold))
                                .foregroundStyle(Color.risoInk)
                            + Text(" — still counts \(unit).")
                                .font(.risoBody(12, .regular))
                                .foregroundStyle(Color.risoMuted))
                        }

                        // Error
                        if let error {
                            Text(error)
                                .font(.risoBody(11, .semibold))
                                .foregroundStyle(Color.risoRed)
                        }
                    }
                    .padding(Riso.gutter)
                }
            }
            .navigationTitle("Smaller version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { onSave() }
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoBlue)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
