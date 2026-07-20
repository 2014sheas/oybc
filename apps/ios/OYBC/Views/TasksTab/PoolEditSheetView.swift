import SwiftUI

/// PoolEditSheetView — Task Pools + Recurring Boards Rework (P2). The
/// Tasks-tab pool editor for the new `Pool` entity.
///
/// **NOT** the legacy `PoolEditSheet` in
/// `Views/ProfileTab/DefaultPoolsListView.swift`, which keeps editing
/// `DefaultPool` rows unchanged until P7 — that sheet is untouched. This
/// is a separate view for `Pool` rows, extending that sheet's baseline
/// (grabber / header / chips / add-row / picker / preview / footer) with
/// a NAME field replacing the old timeframe-keyed FEEDS segmented. See
/// docs/POOLS_RECURRING.md §Surfaces item 2 + the handoff screenshot
/// `02-pool-edit-sheet.png`.
///
/// **NO board-related actions render here** (locked decision) — this
/// sheet only populates the pool; boards pull pools in from the wizard
/// side.
///
/// Owns its own persistence (via `AppDatabase+Pools.swift`'s
/// `createPoolAndEnqueue` / `updatePoolAndEnqueue` /
/// `softDeletePoolAndEnqueue`) and busy/error state — mirrors web's
/// `PoolEditSheet.tsx` rather than the legacy iOS sheet's
/// "caller persists" pattern, so quick-add / chip-remove / delete are all
/// disabled while a save or delete is in flight (a web parity lesson:
/// P2 Task 2 review caught a double-submit gap from NOT gating this).
struct PoolEditSheetView: View {

    /// The pool being edited. `nil` ⇒ create mode ("New pool").
    let pool: Pool?
    /// Active (non-deleted) recurring-board templates — used only to
    /// compute the deck-preview line's floor (smallest consuming floor,
    /// else the 3×3-FREE default 8). Mirrors web's `poolDeckPreview.ts`.
    let templates: [RecurringBoardTemplate]
    /// Read reactively (`@Observable`) so a quick-added or library-picked
    /// task's title resolves immediately once the library reloads.
    let library: TaskLibraryViewModel
    let userId: String
    /// Fired after a successful create or save.
    let onSaved: () -> Void
    /// Fired after a successful delete.
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var poolTaskIds: [String] = []
    @State private var showLibraryPicker = false
    @State private var librarySearch = ""
    @State private var confirmingDelete = false
    @State private var busy = false
    @State private var errorMessage: String?

    private var isEditMode: Bool { pool != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !poolTaskIds.isEmpty && !busy }

    private var selectedTasks: [Task] {
        poolTaskIds.compactMap { id in library.libraryTasks.first { $0.id == id } }
    }

    private var libraryResults: [Task] {
        let selected = Set(poolTaskIds)
        let query = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return library.libraryTasks
            .filter { !selected.contains($0.id) }
            .filter { query.isEmpty || $0.title.lowercased().contains(query) }
    }

    private var deckPreviewText: String {
        Self.formatDeckPreview(
            taskCount: poolTaskIds.count,
            deckFloor: Self.computeDeckFloor(templates: templates, poolId: pool?.id ?? "")
        )
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.risoPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                grabber
                header
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        nameField
                        tasksSection
                        Text(deckPreviewText)
                            .font(.risoBody(12.5, .semibold)).foregroundStyle(Color.risoMuted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
                            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .strokeBorder(Color.risoInk.opacity(0.4),
                                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.risoBody(13, .semibold)).foregroundStyle(Color.risoRed)
                        }
                    }
                    .padding(.horizontal, Riso.gutter).padding(.bottom, 18)
                }
                footer
            }
        }
        .onAppear { seedForm() }
    }

    // MARK: - Header

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.risoInk.opacity(0.2))
            .frame(width: 36, height: 4).padding(.top, 10).padding(.bottom, 14)
    }

    private var header: some View {
        HStack {
            Text(isEditMode ? "Edit pool" : "New pool")
                .font(.risoHead(19, .extraBold)).foregroundStyle(Color.risoInk)
            Spacer()
            RisoButton(title: "Close", kind: .neutral) { dismiss() }
                .disabled(busy)
        }
        .padding(.horizontal, Riso.gutter).padding(.bottom, 20)
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAME").font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
            RisoTextField(placeholder: "e.g. \"Evening wind-down\"", text: $name)
                .disabled(busy)
        }
    }

    // MARK: - Tasks

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TASKS (\(poolTaskIds.count))")
                .font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
            Text("Add a few tasks — boards deal their squares from this list.")
                .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)

            if !selectedTasks.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(selectedTasks, id: \.id) { task in taskChip(task) }
                }
            }

            Text("ADD TASKS").font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
                .padding(.top, 4)

            RisoQuickAddRowView(
                userId: userId,
                defaultTimeframe: nil,
                defaultStartDate: nil,
                defaultEndDate: nil,
                onTaskCreated: { taskId, _, _ in
                    if !poolTaskIds.contains(taskId) { poolTaskIds.append(taskId) }
                },
                onPendingCreated: nil,
                onLibraryReloadRequested: { library.loadLibrary(userId: userId) }
            )
            .disabled(busy)

            libraryPickerToggle
            if showLibraryPicker { libraryPicker }
        }
    }

    private func taskChip(_ task: Task) -> some View {
        HStack(spacing: 5) {
            Text(task.title.isEmpty ? "(untitled task)" : task.title)
                .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoInk).lineLimit(1)
            Button {
                poolTaskIds.removeAll { $0 == task.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.risoInk)
            }
            .disabled(busy)
        }
        .padding(.vertical, 5).padding(.leading, 10).padding(.trailing, 7)
        .background(Capsule().fill(Color.risoPaper2))
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
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
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var libraryPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.risoMuted)
                TextField("Search your tasks…", text: $librarySearch)
                    .font(.risoBody(13, .regular)).foregroundStyle(Color.risoInk)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
            }
            .padding(10)

            Divider().background(Color.risoInk.opacity(0.08))

            if libraryResults.isEmpty {
                Text(librarySearch.isEmpty ? "Every library task is already in this pool." : "No matches.")
                    .font(.risoBody(12.5, .regular)).foregroundStyle(Color.risoMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(14)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(libraryResults, id: \.id) { task in
                            Button {
                                if !poolTaskIds.contains(task.id) { poolTaskIds.append(task.id) }
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
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
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

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                RisoButton(title: "Cancel", kind: .neutral, fullWidth: true) { dismiss() }
                    .disabled(busy)
                RisoButton(title: isEditMode ? "Save" : "Create pool", kind: .primary, fullWidth: true) {
                    handleSave()
                }
                .opacity(canSave ? 1 : 0.45)
                .disabled(!canSave)
            }

            if isEditMode {
                if confirmingDelete {
                    deleteConfirmBlock
                } else {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Text("Delete pool")
                            .font(.risoBody(14, .semibold)).foregroundStyle(Color.risoRed)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
        }
        .padding(.horizontal, Riso.gutter).padding(.top, 14).padding(.bottom, 20)
        .overlay(Rectangle().fill(Color.risoInk).frame(height: Riso.Keyline.dense), alignment: .top)
    }

    private var deleteConfirmBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete \"\(pool?.name ?? "")\"? It detaches from any repeating boards and core defaults that draw from it — tasks are never deleted.")
                .font(.risoBody(13, .semibold)).foregroundStyle(Color.risoInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                RisoButton(title: "Cancel", kind: .neutral, small: true) { confirmingDelete = false }
                    .disabled(busy)
                RisoButton(title: "Delete", kind: .primary, small: true) { handleDelete() }
                    .disabled(busy)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoRed, lineWidth: Riso.Keyline.container))
    }

    // MARK: - Persistence

    private func handleSave() {
        guard canSave else { return }
        busy = true
        errorMessage = nil
        let uid = userId
        let taskIds = poolTaskIds
        let trimmed = trimmedName
        let existing = pool

        _Concurrency.Task {
            do {
                let now = AppDatabase.currentTimestamp()
                if let existing {
                    _ = try await _Concurrency.Task.detached(priority: .userInitiated) {
                        try AppDatabase.shared.updatePoolAndEnqueue(
                            id: existing.id, name: trimmed, taskIds: taskIds, now: now
                        )
                    }.value
                } else {
                    _ = try await _Concurrency.Task.detached(priority: .userInitiated) {
                        try AppDatabase.shared.createPoolAndEnqueue(
                            userId: uid, name: trimmed, taskIds: taskIds, now: now
                        )
                    }.value
                }
                await MainActor.run {
                    busy = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    busy = false
                    errorMessage = "Could not save pool: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleDelete() {
        guard let existing = pool, !busy else { return }
        busy = true
        errorMessage = nil

        _Concurrency.Task {
            do {
                try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.softDeletePoolAndEnqueue(
                        id: existing.id, now: AppDatabase.currentTimestamp()
                    )
                }.value
                await MainActor.run {
                    busy = false
                    onDeleted()
                }
            } catch {
                await MainActor.run {
                    busy = false
                    errorMessage = "Could not delete pool: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Helpers

    private func risoKind(_ type: TaskType) -> RisoTaskKind {
        switch type {
        case .normal: return .normal
        case .counting: return .counting
        case .compound: return .compound
        case .achievement: return .achievement
        }
    }

    private func seedForm() {
        guard let pool else {
            name = ""; poolTaskIds = []
            return
        }
        name = pool.name
        poolTaskIds = pool.taskIds
    }

    // MARK: - Deck preview (page-local; mirrors web `poolDeckPreview.ts` —
    // NOT the shared `PoolHealth.formatPoolShortWarning`, which names the
    // consuming template/timeframe for the pool-CARD warning line instead)

    private struct DeckFloor {
        let boardSize: Int
        let floor: Int
    }

    private static let defaultDeckFloor = DeckFloor(
        boardSize: 3,
        floor: recurringTemplateFillableCellCount(boardSize: 3, centerSquareType: .free)
    )

    /// The floor the deck-preview line measures against: the SMALLEST
    /// fillable floor among the pool's active, non-deleted consumers, or
    /// the 3×3-FREE default when there are none.
    private static func computeDeckFloor(templates: [RecurringBoardTemplate], poolId: String) -> DeckFloor {
        var best: DeckFloor?
        for template in templates {
            guard !template.isDeleted, template.isActive else { continue }
            guard (template.poolIds ?? []).contains(poolId) else { continue }
            let floor = recurringTemplateFillableCellCount(
                boardSize: template.boardSize, centerSquareType: template.centerSquareType
            )
            if best == nil || floor < best!.floor {
                best = DeckFloor(boardSize: template.boardSize, floor: floor)
            }
        }
        return best ?? defaultDeckFloor
    }

    /// `"{N} tasks in the deck · fills a {S}×{S}"` / `"· {shortBy} short of
    /// a {S}×{S}"` — byte-identical to web's `formatDeckPreview`.
    private static func formatDeckPreview(taskCount: Int, deckFloor: DeckFloor) -> String {
        let base = "\(taskCount) task\(taskCount == 1 ? "" : "s") in the deck"
        if taskCount >= deckFloor.floor {
            return "\(base) · fills a \(deckFloor.boardSize)×\(deckFloor.boardSize)"
        }
        let shortBy = deckFloor.floor - taskCount
        return "\(base) · \(shortBy) short of a \(deckFloor.boardSize)×\(deckFloor.boardSize)"
    }
}
