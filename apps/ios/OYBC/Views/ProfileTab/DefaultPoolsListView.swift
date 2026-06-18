import SwiftUI

/// DefaultPoolsListView — Riso-styled Profile sub-page listing default pools.
/// Design: §5a README + screenshot 10.
///
/// Each pool is a keyline card showing name (timeframe label), "FEEDS X" tag,
/// task chips (first 4) + "+N more", task count, and "tap to edit" hint.
/// Tapping a card or the dashed "+ New pool" button opens PoolEditSheet.
///
/// Data: DefaultPool via AppDatabase.fetchDefaultPools (one per timeframe).
/// CRUD reused unchanged: upsertDefaultPool / softDeleteDefaultPool.
struct DefaultPoolsListView: View {

    @EnvironmentObject var authService: AuthService

    @State private var pools: [DefaultPool] = []
    @State private var allTasks: [Task] = []
    @State private var loadError: String?
    @State private var editTarget: PoolEditTarget?

    enum PoolEditTarget: Identifiable {
        case new
        case existing(DefaultPool)
        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let p): return p.id
            }
        }
    }

    var body: some View {
        ZStack {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    RisoSubPageHeader(title: "Default pools")
                        .padding(.top, 16).padding(.bottom, 16)

                    Text("When a core board renews, its squares are dealt from these pools. Extras shuffle into the mix each cycle.")
                        .font(.risoBody(13, .regular)).foregroundStyle(Color.risoMuted)
                        .padding(.horizontal, Riso.gutter).padding(.bottom, 14)

                    if !pools.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(pools, id: \.id) { pool in
                                poolCard(pool).padding(.horizontal, Riso.gutter)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    if let err = loadError {
                        Text(err).font(.risoBody(12, .regular)).foregroundStyle(Color.risoRed)
                            .padding(.horizontal, Riso.gutter).padding(.bottom, 12)
                    }

                    RisoDashedButton(label: "+ New pool") { editTarget = .new }
                        .padding(.horizontal, Riso.gutter).padding(.bottom, 24)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(item: $editTarget) { target in
            PoolEditSheet(
                pool: { if case .existing(let p) = target { return p }; return nil }(),
                allTasks: allTasks,
                onSave: { pool in savePool(pool) },
                onDelete: { id in deletePool(id: id) },
                userId: authService.currentUser?.id ?? ""
            )
        }
        .onAppear { load() }
    }

    // MARK: - Pool card

    private func poolCard(_ pool: DefaultPool) -> some View {
        Button { editTarget = .existing(pool) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(pool.timeframe.risoDisplayName + " pool")
                        .font(.risoHead(17, .extraBold)).foregroundStyle(Color.risoInk)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    feedsTag(pool.timeframe)
                }
                // Task chips (first 4, +N more label)
                taskChips(pool)
                HStack(spacing: 4) {
                    Text("\(pool.taskIds.count)").font(.risoBody(12, .bold)).foregroundStyle(Color.risoInk)
                    Text("tasks").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                    Text("·").foregroundStyle(Color.risoMuted)
                    Text("tap to edit").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                }
            }
            .padding(Riso.cardPadding)
            .risoCard()
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        }
        .buttonStyle(.plain)
    }

    private func feedsTag(_ tf: Timeframe) -> some View {
        Text("FEEDS \(tf.risoDisplayName.uppercased())")
            .font(.risoHead(9, .bold)).tracking(0.4)
            .foregroundStyle(Color.risoPaper)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(Capsule().fill(tf.risoColor))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    @ViewBuilder
    private func taskChips(_ pool: DefaultPool) -> some View {
        let titles = pool.taskIds.compactMap { id in allTasks.first { $0.id == id }?.title }
        let visible = Array(titles.prefix(4))
        let overflow = titles.count - visible.count

        FlowLayout(spacing: 6) {
            ForEach(visible, id: \.self) { title in
                Text(title.isEmpty ? "(untitled)" : title)
                    .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoInk)
                    .padding(.vertical, 4).padding(.horizontal, 9)
                    .background(Capsule().fill(Color.risoPaper))
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                    .lineLimit(1)
            }
            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoBlue)
            }
        }
    }

    // MARK: - Actions

    private func savePool(_ pool: DefaultPool) {
        guard let userId = authService.currentUser?.id else { return }
        // The original row (edit mode only) — used to detect a timeframe
        // change so the stale-timeframe row doesn't linger as a duplicate.
        let original = pools.first { $0.id == pool.id }
        editTarget = nil
        _Concurrency.Task.detached {
            do {
                let now = AppDatabase.currentTimestamp()
                // Editing and the timeframe changed: drop the old row first,
                // then upsert under the new timeframe. (upsert keys by
                // (userId, timeframe), so this also dedups the create path.)
                if let original, original.timeframe != pool.timeframe {
                    try AppDatabase.shared.softDeleteDefaultPoolAndEnqueue(id: original.id, now: now)
                }
                try AppDatabase.shared.upsertDefaultPoolAndEnqueue(
                    userId: userId, timeframe: pool.timeframe, taskIds: pool.taskIds, now: now
                )
                await MainActor.run { load() }
            } catch { print("[DefaultPoolsListView] savePool failed: \(error)") }
        }
    }

    private func deletePool(id: String) {
        guard authService.currentUser?.id != nil else { return }
        editTarget = nil
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.softDeleteDefaultPoolAndEnqueue(
                    id: id, now: AppDatabase.currentTimestamp()
                )
                await MainActor.run { load() }
            } catch { print("[DefaultPoolsListView] deletePool failed: \(error)") }
        }
    }

    private func load() {
        guard let userId = authService.currentUser?.id else { return }
        _Concurrency.Task.detached {
            do {
                let loaded = try AppDatabase.shared.fetchDefaultPools(userId: userId)
                let tasks = try AppDatabase.shared.fetchTasks(userId: userId)
                await MainActor.run {
                    pools = loaded
                    allTasks = tasks
                    loadError = nil
                }
            } catch {
                await MainActor.run { loadError = error.localizedDescription }
            }
        }
    }
}

// MARK: - PoolEditSheet

/// Bottom sheet for creating or editing a DefaultPool.
/// Design: screenshot 17 / §5a.
///
/// Name (= timeframe label — existing model is timeframe-keyed, one per
/// timeframe per user) · Feeds timeframe segmented (tints to the color) ·
/// Tasks as removable chips + "Add a task…" picker · dashed live preview.
///
/// The existing model stores taskIds not raw strings, so "Add a task…" opens
/// a library picker (search field + scrollable list) rather than free typing.
/// Delete calls softDeleteDefaultPool. Save calls saveDefaultPool.
struct PoolEditSheet: View {

    let pool: DefaultPool?
    let allTasks: [Task]
    let onSave: (DefaultPool) -> Void
    let onDelete: (String) -> Void
    /// Owner id for newly-created pools. Passed in (rather than read from
    /// `@EnvironmentObject AuthService`) so the sheet stays snapshot-testable.
    let userId: String

    @Environment(\.dismiss) private var dismiss

    @State private var timeframe: Timeframe = .weekly
    @State private var selectedIds: [String] = []
    @State private var searchDraft: String = ""
    @State private var showPicker = false

    private var isEditMode: Bool { pool != nil }
    private var canSave: Bool { !selectedIds.isEmpty }
    private var pickableTasks: [Task] { allTasks.filter { $0.type != .achievement } }

    private var filteredPickable: [Task] {
        let q = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return pickableTasks.filter { !selectedIds.contains($0.id) } }
        return pickableTasks.filter {
            !selectedIds.contains($0.id) && $0.title.lowercased().contains(q)
        }
    }

    private var selectedTasks: [Task] {
        selectedIds.compactMap { id in allTasks.first { $0.id == id } }
    }

    private var previewText: String {
        "Feeds \(timeframe.risoDisplayName) boards · \(selectedIds.count) task\(selectedIds.count == 1 ? "" : "s") in the deck"
    }

    var body: some View {
        ZStack { Color.risoPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(Color.risoInk.opacity(0.2))
                    .frame(width: 36, height: 4).padding(.top, 10).padding(.bottom, 14)
                HStack {
                    Text(isEditMode ? "Edit pool" : "New pool")
                        .font(.risoHead(19, .extraBold)).foregroundStyle(Color.risoInk)
                    Spacer()
                    RisoButton(title: "Close", kind: .neutral) { dismiss() }
                }
                .padding(.horizontal, Riso.gutter).padding(.bottom, 20)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // Feeds timeframe
                        VStack(alignment: .leading, spacing: 6) {
                            Text("FEEDS").font(.risoBody(11, .bold)).tracking(1.1)
                                .foregroundStyle(Color.risoMuted)
                            RisoSegmented(
                                options: [(Timeframe.daily, "Daily"), (.weekly, "Weekly"),
                                          (.monthly, "Monthly"), (.yearly, "Yearly")],
                                selection: $timeframe,
                                selectedFill: { $0.risoColor }
                            )
                        }

                        // Tasks section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TASKS (\(selectedIds.count))".uppercased())
                                .font(.risoBody(11, .bold)).tracking(1.1)
                                .foregroundStyle(Color.risoMuted)
                            if selectedTasks.isEmpty {
                                Text("Add a few tasks — boards deal their squares from this list.")
                                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                            } else {
                                FlowLayout(spacing: 6) {
                                    ForEach(selectedTasks, id: \.id) { task in
                                        taskChip(task)
                                    }
                                }
                            }
                            // Add row
                            addTaskRow
                        }

                        // Preview
                        Text(previewText)
                            .font(.risoBody(13, .semibold)).foregroundStyle(Color.risoMuted)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(12)
                            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
                            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .strokeBorder(Color.risoInk.opacity(0.4),
                                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))

                        // Action buttons
                        HStack(spacing: 10) {
                            RisoButton(title: "Cancel", kind: .neutral, fullWidth: true) { dismiss() }
                            RisoButton(title: isEditMode ? "Save" : "Create pool",
                                       kind: .primary, fullWidth: true) { submitForm() }
                                .opacity(canSave ? 1 : 0.45).disabled(!canSave)
                        }

                        if isEditMode, let p = pool {
                            Button { onDelete(p.id) } label: {
                                Text("Delete pool")
                                    .font(.risoBody(14, .semibold)).foregroundStyle(Color.risoRed)
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Riso.gutter).padding(.bottom, 32)
                }
            }
        }
        .sheet(isPresented: $showPicker) { taskPickerSheet }
        .onAppear { seedForm() }
    }

    // MARK: - Sub-views

    private func taskChip(_ task: Task) -> some View {
        HStack(spacing: 5) {
            Text(task.title.isEmpty ? "(untitled)" : task.title)
                .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoInk).lineLimit(1)
            Button {
                selectedIds.removeAll { $0 == task.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.risoInk)
            }
        }
        .padding(.vertical, 5).padding(.leading, 10).padding(.trailing, 7)
        .background(Capsule().fill(Color.risoPaper2))
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    private var addTaskRow: some View {
        HStack(spacing: 8) {
            RisoTextField(placeholder: "Add a task…", text: $searchDraft)
            RisoButton(title: "Add", kind: .primary) { showPicker = true }
        }
    }

    private var taskPickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.risoPaper.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Search field in picker
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.risoMuted)
                        TextField("Search tasks…", text: $searchDraft)
                            .font(.risoBody(14, .regular)).foregroundStyle(Color.risoInk)
                            .textInputAutocapitalization(.never).disableAutocorrection(true)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
                    .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                    .padding(.horizontal, Riso.gutter).padding(.top, 12).padding(.bottom, 8)

                    if filteredPickable.isEmpty {
                        Spacer()
                        Text(pickableTasks.isEmpty
                             ? "No tasks in your library yet."
                             : "No tasks match \"\(searchDraft)\".")
                            .font(.risoBody(13, .regular)).foregroundStyle(Color.risoMuted)
                            .multilineTextAlignment(.center).padding(.horizontal, Riso.gutter)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredPickable, id: \.id) { task in
                                    Button {
                                        selectedIds.append(task.id)
                                        searchDraft = ""
                                        showPicker = false
                                    } label: {
                                        HStack(spacing: 10) {
                                            RisoTypeBadge(kind: risoKind(task.type), style: .letterSquare)
                                            Text(task.title.isEmpty ? "(untitled)" : task.title)
                                                .font(.risoBody(14, .semibold)).foregroundStyle(Color.risoInk)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: "plus")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(Color.risoMuted)
                                        }
                                        .padding(.vertical, 12).padding(.horizontal, Riso.gutter)
                                    }
                                    .buttonStyle(.plain)
                                    Divider().background(Color.risoInk.opacity(0.08))
                                        .padding(.horizontal, Riso.gutter)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add a task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showPicker = false }
                        .font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
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
        guard let p = pool else {
            timeframe = .weekly; selectedIds = []
            return
        }
        timeframe = p.timeframe
        selectedIds = p.taskIds
    }

    private func submitForm() {
        guard canSave else { return }
        // `savePool` routes through `upsertDefaultPoolAndEnqueue`, which owns
        // `version`/`updatedAt` and keys by (userId, timeframe). We only carry
        // the chosen timeframe + taskIds; the `id` lets `savePool` find the
        // original row to detect a timeframe change (edit mode).
        let now = AppDatabase.currentTimestamp()
        if let existing = pool {
            var updated = existing
            updated.timeframe = timeframe
            updated.taskIds = selectedIds
            onSave(updated)
        } else {
            onSave(DefaultPool(
                id: UUID().uuidString, userId: userId,
                timeframe: timeframe, taskIds: selectedIds,
                createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1,
                isDeleted: false, deletedAt: nil
            ))
        }
    }
}

// MARK: - FlowLayout

/// Simple left-to-right wrapping layout for tag/chip rows.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0; var x: CGFloat = 0; var rowH: CGFloat = 0
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > width && x > 0 { height += rowH + spacing; x = 0; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: height + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX; var y: CGFloat = bounds.minY; var rowH: CGFloat = 0
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX {
                y += rowH + spacing; x = bounds.minX; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
