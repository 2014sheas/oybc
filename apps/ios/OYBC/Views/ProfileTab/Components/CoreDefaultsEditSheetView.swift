import SwiftUI

/// CoreDefaultsEditSheetView — Task Pools + Recurring Boards Rework (P7),
/// docs/POOLS_RECURRING.md §Surfaces item 9 ("defaults bottom sheet").
///
/// Authors ONE timeframe's `CoreBoardDefault` row — BOTH `corePoolIds`
/// (via the shared `PoolPickerSheetView`, item 10) AND `coreDefaultTaskIds`
/// (chips + quick-add, reusing `RisoCoreDefaultChipStripView`'s existing
/// plain/manual chip split from the P5 core-setup step) — together, in
/// ONE `upsertCoreBoardDefaultAndEnqueue` call. Never uses the partial
/// `upsertCorePoolIdsAndEnqueue` wrapper (that one is the P5 checkbox's
/// preserve-the-other-field path; this sheet always has both fields in
/// hand).
///
/// Pool-sourced chips render plain / non-removable here (matching the P5
/// wizard chip strip's rationale: it came from an attached pool, not this
/// sheet directly — detach the pool via the picker instead). Individual
/// `coreDefaultTaskIds` chips are the removable (blue) layer.
///
/// No fillable-floor gate on Save — `CoreBoardDefault` only PRE-FILLS a
/// future core-board setup, which already floor-gates at creation time
/// (docs/POOLS_RECURRING.md §Behavior invariants lists core setup / wizard
/// Next / roster Save as the three floor-gate points; this sheet isn't
/// one of them).
struct CoreDefaultsEditSheetView: View {

    let timeframe: Timeframe
    /// The existing row, or `nil` when the user hasn't set one up yet.
    let coreDefault: CoreBoardDefault?
    /// The user's non-deleted pools, for the pool picker.
    let pools: [Pool]
    /// The user's non-deleted tasks, for resolving chip titles + the
    /// quick-add row's library-poll candidates.
    let tasks: [Task]
    /// Active templates — only used to compute `PoolPickerSheetView`'s
    /// per-pool health note and the create-mode deck-preview floor.
    let templates: [RecurringBoardTemplate]
    /// Read reactively so a quick-added task's title resolves immediately.
    let library: TaskLibraryViewModel
    let userId: String
    /// Fired after a successful save.
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var poolIdsDraft: Set<String> = []
    @State private var coreDefaultTaskIdsDraft: [String] = []
    /// Local copy of `pools` so a freshly-created pool (via the picker's
    /// "+ Build a new pool…") shows up immediately without waiting for the
    /// caller's own reload.
    @State private var localPools: [Pool] = []
    @State private var showPoolPicker = false
    @State private var busy = false
    @State private var errorMessage: String?

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

    /// The resolved prefill — pool-union tasks first, then
    /// `coreDefaultTaskIds` — reusing the EXACT same resolution the P5
    /// wizard prefill uses (`BoardWizardViewModel.resolveCoreBoardDefaultPrefill`),
    /// so the chip strip here previews exactly what core-board setup will
    /// pre-fill.
    private var resolved: (selectedTaskIds: Set<String>, poolOrder: [String], pulledPoolIds: [String]) {
        BoardWizardViewModel.resolveCoreBoardDefaultPrefill(
            corePoolIds: Array(poolIdsDraft),
            coreDefaultTaskIds: coreDefaultTaskIdsDraft,
            poolsById: poolsById,
            tasksById: tasksById
        )
    }

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
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $showPoolPicker) {
            PoolPickerSheetView(
                pools: localPools,
                selectedPoolIds: poolIdsDraft,
                healthByPoolId: healthByPoolId,
                templates: templates,
                library: library,
                userId: userId,
                title: "Attach pools",
                onToggle: { poolId in
                    if poolIdsDraft.contains(poolId) {
                        poolIdsDraft.remove(poolId)
                    } else {
                        poolIdsDraft.insert(poolId)
                    }
                },
                onPoolCreated: { newPool in
                    localPools.append(newPool)
                    poolIdsDraft.insert(newPool.id)
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
            Text("\(timeframe.risoDisplayName) defaults")
                .font(.risoHead(19, .extraBold)).foregroundStyle(Color.risoInk)
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
            let attachedNames = resolved.pulledPoolIds.compactMap { poolsById[$0]?.name }
            if attachedNames.isEmpty {
                Text("No pools attached.")
                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(attachedNames, id: \.self) { name in
                        Text(name)
                            .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoInk)
                            .padding(.vertical, 5).padding(.horizontal, 10)
                            .background(Capsule().fill(Color.risoPaper2))
                            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
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
            Text("DEFAULT TASKS").font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
            if resolved.poolOrder.isEmpty {
                Text("No default tasks.")
                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
            } else {
                RisoCoreDefaultChipStripView(
                    orderedTaskIds: resolved.poolOrder,
                    manualTaskIds: Set(coreDefaultTaskIdsDraft),
                    taskById: tasksById,
                    onRemove: { taskId in
                        coreDefaultTaskIdsDraft.removeAll { $0 == taskId }
                    }
                )
            }

            Text("ADD A TASK").font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
                .padding(.top, 4)
            RisoQuickAddRowView(
                userId: userId,
                defaultStartDate: nil,
                defaultEndDate: nil,
                onTaskCreated: { taskId, _, _ in addDefaultTask(taskId) },
                onPendingCreated: nil,
                onLibraryReloadRequested: { library.loadLibrary(userId: userId) },
                libraryTasks: library.browsableTasks,
                selectedIds: resolved.selectedTaskIds,
                onExistingTaskPicked: { task in addDefaultTask(task.id) }
            )
            .padding(12)
            .risoCard(fill: .risoPaper2)
            .risoHardShadow(Riso.Shadow.small)
            .disabled(busy)
        }
    }

    private func addDefaultTask(_ taskId: String) {
        guard !resolved.selectedTaskIds.contains(taskId) else { return }
        coreDefaultTaskIdsDraft.append(taskId)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            RisoButton(title: "Cancel", kind: .neutral, fullWidth: true) { dismiss() }
                .disabled(busy)
            RisoButton(title: "Save", kind: .primary, fullWidth: true) { handleSave() }
                .disabled(busy)
        }
        .padding(.horizontal, Riso.gutter).padding(.top, 14).padding(.bottom, 20)
        .overlay(Rectangle().fill(Color.risoInk).frame(height: Riso.Keyline.dense), alignment: .top)
    }

    // MARK: - Persistence

    private func handleSave() {
        busy = true
        errorMessage = nil
        let uid = userId
        let tf = timeframe
        let corePoolIds = Array(poolIdsDraft)
        let coreDefaultTaskIds = coreDefaultTaskIdsDraft

        _Concurrency.Task {
            do {
                let now = AppDatabase.currentTimestamp()
                _ = try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.upsertCoreBoardDefaultAndEnqueue(
                        userId: uid,
                        timeframe: tf,
                        corePoolIds: corePoolIds,
                        coreDefaultTaskIds: coreDefaultTaskIds,
                        now: now
                    )
                }.value
                await MainActor.run {
                    busy = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    busy = false
                    errorMessage = "Could not save defaults: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Seed

    private func seedForm() {
        localPools = pools
        poolIdsDraft = Set(coreDefault?.corePoolIds ?? [])
        coreDefaultTaskIdsDraft = coreDefault?.coreDefaultTaskIds ?? []
    }
}
