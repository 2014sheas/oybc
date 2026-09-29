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
    /// The roster's achievable pick per template (`rosterVM.mixByTemplateId`
    /// on the owning Board-settings screen) — the sources-native input to
    /// the pool picker's health note (2026-09 audit T2). `nil` while the
    /// roster is still loading.
    let achievableTaskIdsByTemplateId: [String: [String]]?
    /// Read reactively so a quick-added task's title resolves immediately.
    let library: TaskLibraryViewModel
    let userId: String
    /// The user's global "new board" preferences — the inherit fallback for
    /// the BOARD section below (docs/POOLS_RECURRING.md §Per-timeframe size
    /// + centre, owner-decided 2026-09-29).
    let preferences: UserPreferences
    /// Fired after a successful save.
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var poolIdsDraft: Set<String> = []
    @State private var coreDefaultTaskIdsDraft: [String] = []
    /// Per-timeframe size + centre — nil means "nothing explicit yet, show
    /// the resolved global default." Seeded from the row's overrides; Save
    /// writes `.clear` when nil, `.set(x)` otherwise. Never persisted until
    /// the user actually picks a segment / flips the toggle.
    @State private var boardSizeDraft: DefaultBoardSize?
    @State private var centerTypeDraft: DefaultCenterSquareType?
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
        PoolHealth.computePoolHealthByPoolId(
            pools: localPools,
            templates: templates,
            achievableTaskIdsByTemplateId: achievableTaskIdsByTemplateId,
            tasksById: tasksById
        )
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

    // MARK: - Board (size + centre)

    /// The size the segmented control shows: the local draft where the user
    /// has already picked one, else the global "new board" default.
    private var boardSizeSelection: DefaultBoardSize { boardSizeDraft ?? preferences.defaultBoardSize }
    private var centerTypeSelection: DefaultCenterSquareType { centerTypeDraft ?? preferences.defaultCenterType }
    private var hasExplicitBoardOverride: Bool { boardSizeDraft != nil || centerTypeDraft != nil }

    var body: some View {
        ZStack {
            Color.risoPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                grabber
                header
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        boardSection
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

    // MARK: - Board section

    private var boardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BOARD").font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Size").font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
                        .frame(minWidth: 80, alignment: .leading)
                    Spacer()
                    RisoSegmented(
                        options: [(DefaultBoardSize.three, "3×3"),
                                  (DefaultBoardSize.four, "4×4"),
                                  (DefaultBoardSize.five, "5×5")],
                        selection: Binding(
                            get: { boardSizeSelection },
                            set: { newValue in
                                // Same odd/even coercion as the wizard's own
                                // `updateSize`: an even pick forces "no free
                                // space"; crossing back from even to odd
                                // restores a sensible visible default.
                                let oldIsOdd = boardSizeSelection.rawValue % 2 != 0
                                boardSizeDraft = newValue
                                let newIsOdd = newValue.rawValue % 2 != 0
                                if !newIsOdd {
                                    centerTypeDraft = .none
                                } else if !oldIsOdd {
                                    centerTypeDraft = .free
                                }
                            }
                        ),
                        equalWidth: false
                    )
                    // VoiceOver: name the group (web twin: `aria-label="Board size"`);
                    // same pattern as `RisoMemberRuleRowView`'s squares segmented.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Board size")
                }
                .padding(.horizontal, Riso.cardPadding).padding(.vertical, 12)

                // Even boards have no centre concept — hidden, not disabled.
                if boardSizeSelection.rawValue % 2 != 0 {
                    Divider().background(Color.risoInk.opacity(0.12))
                        .padding(.horizontal, Riso.cardPadding)
                    HStack(spacing: 10) {
                        Text("Free space").font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
                        Spacer()
                        RisoPillSwitch(isOn: Binding(
                            get: { centerTypeSelection == .free },
                            set: { isOn in centerTypeDraft = isOn ? .free : DefaultCenterSquareType.none }
                        ))
                        // `RisoPillSwitch` is a label-hidden Toggle — give it the
                        // row's name (web twin: `<label htmlFor>` "Free space").
                        .accessibilityLabel("Free space")
                    }
                    .padding(.horizontal, Riso.cardPadding).padding(.vertical, 12)
                }
            }
            .risoCard()
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)

            if hasExplicitBoardOverride {
                Button {
                    boardSizeDraft = nil
                    centerTypeDraft = nil
                } label: {
                    Text("Use new-board default")
                        .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoBlue)
                        .underline()
                }
                .buttonStyle(.plain)
            } else {
                Text("Using your new-board default")
                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
            }
        }
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
        // Per-timeframe size + centre — this sheet always represents the
        // FULL state (never `.keep`): nil means the user wants "inherit",
        // which must CLEAR a previously-set row override, not leave it
        // stranded. `.set($0)` here passes a concrete enum value (never the
        // bare `.none` literal), so the `.set(.none)`-ambiguity trap doesn't
        // apply.
        let sizePatch: CoreBoardDefaultFieldPatch<DefaultBoardSize> = boardSizeDraft.map { .set($0) } ?? .clear
        let centerPatch: CoreBoardDefaultFieldPatch<DefaultCenterSquareType> = centerTypeDraft.map { .set($0) } ?? .clear

        _Concurrency.Task {
            do {
                let now = AppDatabase.currentTimestamp()
                _ = try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.upsertCoreBoardDefaultAndEnqueue(
                        userId: uid,
                        timeframe: tf,
                        corePoolIds: corePoolIds,
                        coreDefaultTaskIds: coreDefaultTaskIds,
                        defaultBoardSize: sizePatch,
                        defaultCenterType: centerPatch,
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
        boardSizeDraft = coreDefault?.defaultBoardSize
        centerTypeDraft = coreDefault?.defaultCenterType
    }
}
