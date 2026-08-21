import SwiftUI

/// BoardSettingsView — Task Pools + Recurring Boards Rework (P7),
/// docs/POOLS_RECURRING.md §Surfaces item 9. Replaces the retired
/// `RecurringTemplatesView` + `DefaultPoolsListView` Profile sub-pages
/// with ONE page:
///
/// 1. Per-timeframe core-board defaults rows (Daily/Weekly/Monthly/
///    Yearly) — a resolved summary ("No default tasks", never "Not set")
///    that opens `CoreDefaultsEditSheetView` on tap.
/// 2. A repeating-boards roster — ALL spawn records, active AND paused
///    (the safety net for paused boards; unlike the old templates page
///    there's no `+ New` here — creation happens via the wizard's
///    Step-1 "Repeats" control, P4) — with Pause/Resume (reusing
///    `RecurringTemplateCard`'s toggle) and Edit tasks (opens
///    `RepeatingBoardEditSheetView`, a local sheet — no wizard hop).
///
/// Container view stays thin: it owns loading + the two sheet
/// presentations; all form logic lives in the two sheet views.
struct BoardSettingsView: View {
    @EnvironmentObject var authService: AuthService

    @State private var coreDefaultsByTimeframe: [Timeframe: CoreBoardDefault] = [:]
    @State private var pools: [Pool] = []
    @State private var tasks: [Task] = []
    @State private var library = TaskLibraryViewModel()
    @State private var rosterVM = RecurringBoardTemplatesViewModel()
    @State private var loadError: String?

    private enum DefaultsEditTarget: Identifiable {
        case timeframe(Timeframe)
        var id: String {
            switch self {
            case .timeframe(let tf): return tf.rawValue
            }
        }
    }
    private struct RosterEditTarget: Identifiable {
        let template: RecurringBoardTemplate
        var id: String { template.id }
    }

    @State private var defaultsEditTarget: DefaultsEditTarget?
    @State private var rosterEditTarget: RosterEditTarget?

    /// `.custom` is excluded — same reason as everywhere else in this
    /// feature: a "default" tied to a computed recurring window has no
    /// semantic for a custom-window board.
    private static let coreTimeframes: [Timeframe] = [.daily, .weekly, .monthly, .yearly]

    private var tasksById: [String: Task] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    }
    private var poolsById: [String: Pool] {
        Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })
    }

    var body: some View {
        ZStack {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    RisoSubPageHeader(title: "Board settings")
                        .padding(.top, 16)
                        .padding(.bottom, 16)

                    Text("Core-board defaults pre-fill setup for a fresh Daily/Weekly/Monthly/Yearly board. Repeating boards print a fresh card each cycle from a pool.")
                        .font(.risoBody(13, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 14)

                    sectionLabel("New board defaults")
                    newBoardsCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 20)

                    sectionLabel("Core board defaults")
                    VStack(spacing: 10) {
                        ForEach(Self.coreTimeframes, id: \.self) { tf in
                            defaultsRow(tf)
                        }
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 20)

                    sectionLabel("Repeating boards")
                    rosterSection
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 20)

                    if let loadError {
                        Text(loadError)
                            .font(.risoBody(12, .regular)).foregroundStyle(Color.risoRed)
                            .padding(.horizontal, Riso.gutter).padding(.bottom, 12)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { reload() }
        .sheet(item: $defaultsEditTarget) { target in
            switch target {
            case .timeframe(let tf):
                CoreDefaultsEditSheetView(
                    timeframe: tf,
                    coreDefault: coreDefaultsByTimeframe[tf],
                    pools: pools,
                    tasks: tasks,
                    templates: rosterVM.templates,
                    library: library,
                    userId: authService.currentUser?.id ?? "",
                    onSaved: {
                        defaultsEditTarget = nil
                        reload()
                    }
                )
            }
        }
        .sheet(item: $rosterEditTarget) { target in
            RepeatingBoardEditSheetView(
                template: target.template,
                pools: pools,
                tasks: tasks,
                templates: rosterVM.templates,
                library: library,
                userId: authService.currentUser?.id ?? "",
                onSaved: {
                    rosterEditTarget = nil
                    reload()
                }
            )
        }
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .risoSectionLabel()
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 8)
    }

    // MARK: - New board defaults card
    //
    // Ported verbatim from the retired `BoardPreferencesView` (Default size /
    // Center square / Week starts). All controls write through
    // `AppDatabase.updateUserPreferences` via the `bind(_:)` helper below.

    private var preferences: UserPreferences { authService.userPreferences }

    private var newBoardsCard: some View {
        VStack(spacing: 0) {
            segRow(label: "Default size",
                   options: [(DefaultBoardSize.three, "3×3"),
                             (DefaultBoardSize.four, "4×4"),
                             (DefaultBoardSize.five, "5×5")],
                   selection: bind(\.defaultBoardSize))
            rowDivider
            segRow(label: "Center square",
                   options: [(DefaultCenterSquareType.free, "Free"),
                             (DefaultCenterSquareType.none, "None")],
                   selection: bind(\.defaultCenterType))
            rowDivider
            VStack(alignment: .leading, spacing: 4) {
                segRow(label: "Week starts",
                       options: [(WeekStartDay.monday, "Mon"),
                                 (WeekStartDay.sunday, "Sun")],
                       selection: bind(\.weekStartDay))
                Text("Sets when weekly boards reset and renew.")
                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, Riso.cardPadding).padding(.bottom, 10)
            }
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private func segRow<V: Hashable>(
        label: String,
        options: [(V, String)],
        selection: Binding<V>
    ) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
                .frame(minWidth: 80, alignment: .leading)
            Spacer()
            // Sizes-to-content (not `.fixedSize()`, which collapsed the
            // equal-width layout into mismatched, clipping pills).
            RisoSegmented(options: options.map { (value: $0.0, label: $0.1) },
                          selection: selection,
                          equalWidth: false)
        }
        .padding(.horizontal, Riso.cardPadding)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Divider().background(Color.risoInk.opacity(0.12))
            .padding(.horizontal, Riso.cardPadding)
    }

    /// Two-way Binding for a UserPreferences field that writes through
    /// AppDatabase.updateUserPreferences (bumps version/updatedAt + enqueues sync).
    private func bind<Value>(
        _ keyPath: WritableKeyPath<UserPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { newValue in
                guard let userId = authService.currentUser?.id else { return }
                do {
                    _ = try AppDatabase.shared.updateUserPreferences(userId: userId) { current in
                        var next = current
                        next[keyPath: keyPath] = newValue
                        return next
                    }
                } catch {
                    dlog("⚠️ BoardSettingsView updateUserPreferences failed: \(error)")
                }
            }
        )
    }

    // MARK: - Core-board defaults rows

    private func defaultsRow(_ tf: Timeframe) -> some View {
        let coreDefault = coreDefaultsByTimeframe[tf]
        let resolved = BoardWizardViewModel.resolveCoreBoardDefaultPrefill(
            corePoolIds: coreDefault?.corePoolIds ?? [],
            coreDefaultTaskIds: coreDefault?.coreDefaultTaskIds ?? [],
            poolsById: poolsById,
            tasksById: tasksById
        )
        let poolNames = resolved.pulledPoolIds.compactMap { poolsById[$0]?.name }
        let summary = Self.formatDefaultsSummary(resolvedCount: resolved.selectedTaskIds.count, poolNames: poolNames)

        return Button { defaultsEditTarget = .timeframe(tf) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tf.risoDisplayName)
                        .font(.risoHead(15, .bold)).foregroundStyle(Color.risoInk)
                    Text(summary)
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(resolved.selectedTaskIds.isEmpty ? Color.risoMuted : Color.risoInk)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(Riso.cardPadding)
            .risoCard()
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        }
        .buttonStyle(.plain)
    }

    /// Pure, testable summary line for a defaults row. Copy rule (owner-
    /// enforced, docs/POOLS_RECURRING.md §Behavior invariants): "No
    /// default tasks", never "Not set"; "from", never "deals from".
    static func formatDefaultsSummary(resolvedCount: Int, poolNames: [String]) -> String {
        guard resolvedCount > 0 else { return "No default tasks" }
        let taskPart = "\(resolvedCount) default task\(resolvedCount == 1 ? "" : "s")"
        guard !poolNames.isEmpty else { return taskPart }
        let poolPart = poolNames.count == 1 ? "from \(poolNames[0])" : "from \(poolNames.count) pools"
        return "\(taskPart) · \(poolPart)"
    }

    // MARK: - Repeating-boards roster

    @ViewBuilder
    private var rosterSection: some View {
        if rosterVM.templates.isEmpty {
            Text("No repeating boards yet — turn one on from a board's \"Repeats\" setting when you create it, or \"Repeat this board…\" from an existing one.")
                .font(.risoBody(12.5, .regular))
                .foregroundStyle(Color.risoMuted)
        } else {
            VStack(spacing: 10) {
                ForEach(rosterVM.templates, id: \.id) { tpl in
                    RecurringTemplateCard(
                        template: tpl,
                        attentionReason: rosterVM.attentionByTemplateId[tpl.id],
                        poolPreview: rosterVM.poolPreviewByTemplateId[tpl.id] ?? [],
                        poolPreviewOverflow: rosterVM.poolPreviewOverflowByTemplateId[tpl.id] ?? 0,
                        poolTaskCount: rosterVM.mixByTemplateId[tpl.id]?.count,
                        onEdit: { rosterEditTarget = RosterEditTarget(template: tpl) },
                        onToggleActive: { newValue in setActive(tpl, newValue) },
                        onDelete: { deleteTemplate(id: tpl.id) },
                        onAddTasks: { rosterEditTarget = RosterEditTarget(template: tpl) }
                    )
                }
            }
        }
    }

    // MARK: - Roster actions

    /// Pause / resume a repeating board. Mirrors the retired
    /// `RecurringTemplatesView.setActive` verbatim.
    private func setActive(_ tpl: RecurringBoardTemplate, _ newValue: Bool) {
        guard let userId = authService.currentUser?.id else { return }
        let now = AppDatabase.currentTimestamp()
        var updated = tpl; updated.isActive = newValue
        updated.updatedAt = now; updated.version += 1
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
                    updated, operation: .update, now: now
                )
                await MainActor.run { rosterVM.reloadAsync(userId: userId) }
            } catch { dlog("[BoardSettingsView] toggle active failed: \(error)") }
        }
    }

    /// Soft-delete a repeating board. Spawned boards are intentionally
    /// left untouched (see the card's confirm copy).
    private func deleteTemplate(id: String) {
        guard let userId = authService.currentUser?.id else { return }
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.softDeleteRecurringBoardTemplateAndEnqueue(
                    id: id, now: AppDatabase.currentTimestamp()
                )
                await MainActor.run { rosterVM.reloadAsync(userId: userId) }
            } catch { dlog("[BoardSettingsView] deleteTemplate failed: \(error)") }
        }
    }

    // MARK: - Loading

    private func reload() {
        guard let userId = authService.currentUser?.id else { return }
        rosterVM.reloadAsync(userId: userId)
        library.loadLibrary(userId: userId)
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                let defaults = try AppDatabase.shared.fetchCoreBoardDefaults(userId: userId)
                let poolsFetched = try AppDatabase.shared.fetchPools(userId: userId)
                let tasksFetched = try AppDatabase.shared.fetchTasks(userId: userId)
                var byTimeframe: [Timeframe: CoreBoardDefault] = [:]
                for d in defaults { byTimeframe[d.timeframe] = d }
                await MainActor.run {
                    coreDefaultsByTimeframe = byTimeframe
                    pools = poolsFetched
                    tasks = tasksFetched
                    loadError = nil
                }
            } catch {
                await MainActor.run {
                    loadError = "Failed to load board settings: \(error.localizedDescription)"
                }
            }
        }
    }
}
