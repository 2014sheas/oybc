import SwiftUI

/// RepeatingBoardEditSheetView — Task Pools + Recurring Boards Rework
/// (P7), docs/POOLS_RECURRING.md §Surfaces item 9 ("roster edit sheet").
///
/// Edits a repeating board's (spawn record's) mix DIRECTLY on its native
/// `poolIds` / `manualTaskIds` / `removedTaskIds` fields — no wizard hop.
/// Pool toggles UNION with the mix per the locked "Union rule"
/// (docs/POOLS_RECURRING.md §Data model): pulling a pool never resets the
/// manual layer; untoggling one removes only ITS non-manual,
/// no-longer-otherwise-supplied tasks (`PoolMix.clearRemovalsForUntoggle`).
/// The saved `Pool` itself is never mutated by either action.
///
/// Unlike `BoardWizardViewModel.pullPool`/`untogglePool` (which maintain a
/// separate flat `selectedTaskIds` the wizard UI needs for drag-reorder /
/// center-pinning), this sheet has no such derived selection to keep in
/// sync — `poolIds`/`manualTaskIds`/`removedTaskIds` ARE the source of
/// truth here, and the displayed mix is simply
/// `PoolMix.resolveMix(draft, ...)` recomputed on every render. So a pool
/// toggle only ever mutates `draft.poolIds` (+ `removedTaskIds` on
/// untoggle, via `clearRemovalsForUntoggle` — same call the wizard makes).
///
/// Save is floor-gated (`recurringTemplateFillableCellCount`) — one of the
/// three floor-gate points named in docs/POOLS_RECURRING.md §Behavior
/// invariants (core setup, wizard Next, roster Save). Persists via
/// `AppDatabase.saveRecurringBoardTemplateAndEnqueue` — the same
/// atomic-write-plus-enqueue helper `BoardSettingsView`'s Pause/Resume
/// toggle uses, just with the fuller field set.
struct RepeatingBoardEditSheetView: View {

    /// The user's non-deleted pools, for the pool picker.
    let pools: [Pool]
    /// The user's non-deleted tasks, for resolving chip titles + the
    /// quick-add row's library-poll candidates.
    let tasks: [Task]
    /// ALL active repeating boards — batched ONCE for `PoolPickerSheetView`'s
    /// per-pool health note (never per-row).
    let templates: [RecurringBoardTemplate]
    /// Read reactively so a quick-added task's title resolves immediately.
    let library: TaskLibraryViewModel
    let userId: String
    /// Fired after a successful save.
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Working copy of the template being edited. `RecurringBoardTemplate`
    /// already conforms to `PoolMixSource`, so it can be passed straight to
    /// `PoolMix.resolveMix`/`clearRemovalsForUntoggle` without an
    /// intermediate record type.
    @State private var draft: RecurringBoardTemplate
    /// Local copy of `pools` so a freshly-created pool (via the picker's
    /// "+ Build a new pool…") shows up immediately.
    @State private var localPools: [Pool] = []
    @State private var showPoolPicker = false
    @State private var busy = false
    @State private var errorMessage: String?

    init(
        template: RecurringBoardTemplate,
        pools: [Pool],
        tasks: [Task],
        templates: [RecurringBoardTemplate],
        library: TaskLibraryViewModel,
        userId: String,
        onSaved: @escaping () -> Void
    ) {
        self.pools = pools
        self.tasks = tasks
        self.templates = templates
        self.library = library
        self.userId = userId
        self.onSaved = onSaved
        _draft = State(initialValue: template)
    }

    private var tasksById: [String: Task] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    }
    private var poolsById: [String: Pool] {
        Dictionary(uniqueKeysWithValues: localPools.map { ($0.id, $0) })
    }
    private var healthByPoolId: [String: PoolHealth.Result] {
        Dictionary(uniqueKeysWithValues: localPools.map { pool in
            (pool.id, PoolHealth.computePoolHealth(pool, templates: templates, poolsById: poolsById, tasksById: tasksById))
        })
    }
    private var mix: ResolveMixResult {
        PoolMix.resolveMix(draft, poolsById: poolsById, tasksById: tasksById)
    }
    private var floor: Int {
        recurringTemplateFillableCellCount(boardSize: draft.boardSize, centerSquareType: draft.centerSquareType)
    }
    private var shortBy: Int { max(0, floor - mix.taskIds.count) }
    private var canSave: Bool { shortBy == 0 && !busy }

    var body: some View {
        ZStack {
            Color.risoPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                grabber
                header
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        poolsSection
                        tasksSection
                        deckPreview
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
        .onAppear { localPools = pools }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $showPoolPicker) {
            PoolPickerSheetView(
                pools: localPools,
                selectedPoolIds: Set(draft.poolIds ?? []),
                healthByPoolId: healthByPoolId,
                templates: templates,
                library: library,
                userId: userId,
                title: "Attach pools",
                onToggle: { poolId in togglePool(poolId) },
                onPoolCreated: { newPool in
                    localPools.append(newPool)
                    pullPool(newPool.id)
                }
            )
        }
    }

    // MARK: - Header

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.risoInk.opacity(0.2))
            .frame(width: 36, height: 4).padding(.top, 10).padding(.bottom, 14)
    }

    private var header: some View {
        HStack {
            Text("Edit \"\(draft.name)\"")
                .font(.risoHead(19, .extraBold)).foregroundStyle(Color.risoInk)
                .lineLimit(1)
            Spacer()
            RisoButton(title: "Close", kind: .neutral) { dismiss() }
                .disabled(busy)
        }
        .padding(.horizontal, Riso.gutter).padding(.bottom, 20)
    }

    // MARK: - Pools

    private var poolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("POOLS").font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
            let poolIds = draft.poolIds ?? []
            if poolIds.isEmpty {
                Text("No pools attached — this is an own-mix repeating board.")
                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(poolIds, id: \.self) { poolId in
                        if let name = poolsById[poolId]?.name {
                            Text(name)
                                .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoInk)
                                .padding(.vertical, 5).padding(.horizontal, 10)
                                .background(Capsule().fill(Color.risoPaper2))
                                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                        }
                    }
                }
            }
            RisoDashedButton(label: "+ Attach a pool…") { showPoolPicker = true }
                .disabled(busy)
        }
    }

    // MARK: - Tasks

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TASKS (\(mix.taskIds.count))").font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
            if mix.taskIds.isEmpty {
                Text("Attach a pool or add a task — boards deal their squares from this mix.")
                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(mix.taskIds, id: \.self) { taskId in
                        if let task = tasksById[taskId] {
                            mixChip(task)
                        }
                    }
                }
            }

            Text("ADD A TASK").font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
                .padding(.top, 4)
            RisoQuickAddRowView(
                userId: userId,
                defaultStartDate: nil,
                defaultEndDate: nil,
                onTaskCreated: { taskId, _, _ in addManualTask(taskId) },
                onPendingCreated: nil,
                onLibraryReloadRequested: { library.loadLibrary(userId: userId) },
                libraryTasks: library.browsableTasks,
                selectedIds: Set(mix.taskIds),
                onExistingTaskPicked: { task in addManualTask(task.id) }
            )
            .padding(12)
            .risoCard(fill: .risoPaper2)
            .risoHardShadow(Riso.Shadow.small)
            .disabled(busy)
        }
    }

    private func mixChip(_ task: Task) -> some View {
        HStack(spacing: 5) {
            Text(task.title.isEmpty ? "(untitled task)" : task.title)
                .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoInk).lineLimit(1)
            Button {
                removeTaskFromMix(task.id)
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

    // MARK: - Deck preview / floor status

    private var deckPreview: some View {
        let text = PoolHealth.formatDeckPreview(
            taskCount: mix.taskIds.count,
            deckFloor: PoolHealth.DeckFloor(boardSize: draft.boardSize, floor: floor)
        )
        return Text(shortBy > 0 ? "\(shortBy) short of a \(draft.boardSize)×\(draft.boardSize) board — \(text)" : text)
            .font(.risoBody(12.5, .semibold))
            .foregroundStyle(shortBy > 0 ? Color.risoRed : Color.risoMuted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            RisoButton(title: "Cancel", kind: .neutral, fullWidth: true) { dismiss() }
                .disabled(busy)
            RisoButton(title: "Save", kind: .primary, fullWidth: true) { handleSave() }
                .opacity(canSave ? 1 : 0.45)
                .disabled(!canSave)
        }
        .padding(.horizontal, Riso.gutter).padding(.top, 14).padding(.bottom, 20)
        .overlay(Rectangle().fill(Color.risoInk).frame(height: Riso.Keyline.dense), alignment: .top)
    }

    // MARK: - Pool-mix mutators (Union rule — see type doc)
    //
    // All delegate to `RepeatingBoardMixEditor` (Helpers/) — the pure,
    // unit-testable extraction of this logic. The view only decides WHICH
    // mutation to call and re-assigns the result to `draft`.

    private func togglePool(_ poolId: String) {
        if (draft.poolIds ?? []).contains(poolId) {
            draft = RepeatingBoardMixEditor.untogglePool(poolId, from: draft, poolsById: poolsById)
        } else {
            draft = RepeatingBoardMixEditor.pullPool(poolId, into: draft, poolsById: poolsById)
        }
    }

    private func pullPool(_ poolId: String) {
        draft = RepeatingBoardMixEditor.pullPool(poolId, into: draft, poolsById: poolsById)
    }

    private func removeTaskFromMix(_ taskId: String) {
        draft = RepeatingBoardMixEditor.removeTaskFromMix(
            taskId, from: draft, poolsById: poolsById, tasksById: tasksById
        )
    }

    private func addManualTask(_ taskId: String) {
        draft = RepeatingBoardMixEditor.addManualTask(taskId, to: draft)
    }

    // MARK: - Persistence

    private func handleSave() {
        guard canSave else { return }
        busy = true
        errorMessage = nil
        let now = AppDatabase.currentTimestamp()
        var updated = draft
        updated.updatedAt = now
        updated.version += 1

        _Concurrency.Task {
            do {
                try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
                        updated, operation: .update, now: now
                    )
                }.value
                await MainActor.run {
                    busy = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    busy = false
                    errorMessage = "Could not save: \(error.localizedDescription)"
                }
            }
        }
    }
}
