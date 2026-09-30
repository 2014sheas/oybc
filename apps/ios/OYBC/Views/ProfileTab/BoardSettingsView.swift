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
///    there's no `+ New` here — creation happens from the Create hub's
///    "Start a recurring board" CTA, or this screen's own "New ›" link,
///    which routes to the same entry) — with Pause/Resume (reusing
///    `RecurringTemplateCard`'s toggle) and Edit (opens the recurring
///    wizard in edit mode via `fullScreenCover` — "EDIT RECURRING BOARD").
///
/// Profile reorg PR3 restructured the groups to "EVERY NEW BOARD" /
/// "PRE-FILLED TASKS BY TIMEFRAME" / "REPEATING BOARDS" (renamed from
/// "New board defaults" / "Core board defaults" / "Repeating boards") and
/// moved the "Recurring board reminders" group to
/// `NotificationPreferencesView` — see `design_handoff_profile_reorg/
/// README.md` §4. This container stays thin: it owns loading + the two
/// sheet presentations; all layout/copy lives in the presentational
/// `BoardSettingsContent` leaf, split out the same way
/// `NotificationPreferencesView`/`NotificationPreferencesContent` already
/// are so the restructured screen is snapshot-testable without
/// Firebase/DB.
struct BoardSettingsView: View {
    @EnvironmentObject var authService: AuthService

    /// Opens the Create tab's recurring-board wizard entry (the same
    /// `enterFreshWizard(startRecurring: true)` path
    /// `CreateHubBoardCTAView(kind: .recurring)` uses) — wired by
    /// `MainTabView` to a cross-tab hop, the way `.createBoard` is
    /// handled for tutorial deep-links. Defaults to a no-op for previews/
    /// tests that don't exercise cross-tab navigation.
    var onNewRepeatingBoard: () -> Void = {}

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

    private var tasksById: [String: Task] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    }
    private var poolsById: [String: Pool] {
        Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })
    }
    private var preferences: UserPreferences { authService.userPreferences }

    var body: some View {
        BoardSettingsContent(
            preferences: preferences,
            coreDefaultsByTimeframe: coreDefaultsByTimeframe,
            poolsById: poolsById,
            tasksById: tasksById,
            templates: rosterVM.templates,
            attentionByTemplateId: rosterVM.attentionByTemplateId,
            taskCountByTemplateId: rosterVM.mixByTemplateId.mapValues { $0.count },
            loadError: loadError,
            onSetDefaultSize: { bind(\.defaultBoardSize).wrappedValue = $0 },
            onSetDefaultTimeframe: { bind(\.defaultTimeframe).wrappedValue = $0 },
            onSetCenterType: { bind(\.defaultCenterType).wrappedValue = $0 },
            onSetWeekStart: { bind(\.weekStartDay).wrappedValue = $0 },
            onTapDefaultsRow: { defaultsEditTarget = .timeframe($0) },
            onNewRepeatingBoard: onNewRepeatingBoard,
            onTapTemplate: { rosterEditTarget = RosterEditTarget(template: $0) },
            onToggleTemplateActive: { tpl, newValue in setActive(tpl, newValue) }
        )
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
                    // Written in the same main-actor commit as `templates`,
                    // so the two always describe the same roster.
                    achievableTaskIdsByTemplateId: rosterVM.mixByTemplateId,
                    library: library,
                    userId: authService.currentUser?.id ?? "",
                    preferences: preferences,
                    onSaved: {
                        defaultsEditTarget = nil
                        reload()
                    }
                )
            }
        }
        .fullScreenCover(item: $rosterEditTarget) { target in
            // Board Creation Split (PR B) — tapping a roster row opens the
            // full recurring wizard in EDIT mode (kicker "EDIT RECURRING
            // BOARD", schedule note "Changes apply from the next board ·
            // current board keeps playing", footer Cancel / "Save
            // Changes") instead of the retired local
            // `RepeatingBoardEditSheetView`. Pause/resume (`setActive`,
            // below) is unaffected — it stays a direct roster-row toggle,
            // no wizard hop.
            BoardWizardView(
                userId: authService.currentUser?.id ?? "",
                preferences: preferences,
                editingTemplate: target.template,
                onCancel: { rosterEditTarget = nil },
                onComplete: { _, _ in
                    rosterEditTarget = nil
                    reload()
                },
                onTemplateComplete: { _ in
                    rosterEditTarget = nil
                    reload()
                }
            )
        }
    }

    // MARK: - Preferences bindings
    //
    // Ported verbatim from the retired `BoardPreferencesView` (Default size /
    // Center square / Week starts). All controls write through
    // `AppDatabase.updateUserPreferences` via the `bind(_:)` helper below.

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

    /// Pure, testable summary line for a defaults row. Copy rule (owner-
    /// enforced, docs/POOLS_RECURRING.md §Behavior invariants): "No
    /// default tasks", never "Not set"; "from", never "deals from".
    /// Mirrors web `formatDefaultsSummary` (`components/boardSettings/`).
    ///
    /// - Parameters:
    ///   - resolvedCount: Number of tasks the row's pools + defaults resolve to.
    ///   - poolNames: Names of the pulled pools.
    ///   - setup: The RESOLVED size + centre when the timeframe explicitly
    ///     overrides either (`hasExplicitCoreBoardSetup` →
    ///     `resolveCoreBoardSetupDefaults`); nil for an inheriting timeframe,
    ///     which shows no suffix.
    /// - Returns: e.g. `"4 default tasks · from Morning Pool · 3×3 · free space"`.
    static func formatDefaultsSummary(
        resolvedCount: Int,
        poolNames: [String],
        setup: CoreBoardSetupDefaults? = nil
    ) -> String {
        let base = formatTasksPart(resolvedCount: resolvedCount, poolNames: poolNames)
        guard let setup else { return base }
        return "\(base) · \(formatSetupSuffix(setup))"
    }

    private static func formatTasksPart(resolvedCount: Int, poolNames: [String]) -> String {
        guard resolvedCount > 0 else { return "No default tasks" }
        let taskPart = "\(resolvedCount) default task\(resolvedCount == 1 ? "" : "s")"
        guard !poolNames.isEmpty else { return taskPart }
        let poolPart = poolNames.count == 1 ? "from \(poolNames[0])" : "from \(poolNames.count) pools"
        return "\(taskPart) · \(poolPart)"
    }

    /// The size / centre suffix on its own: "3×3 · free space", "5×5 · no
    /// free space", or a bare "4×4" (an even board has no centre concept, so
    /// its centre value is never described).
    ///
    /// - Parameter setup: A resolved size + centre pair.
    /// - Returns: The suffix text.
    static func formatSetupSuffix(_ setup: CoreBoardSetupDefaults) -> String {
        let size = "\(setup.boardSize)×\(setup.boardSize)"
        guard setup.boardSize % 2 != 0 else { return size }
        return setup.centerType == .free ? "\(size) · free space" : "\(size) · no free space"
    }

    // MARK: - Roster actions

    /// Pause / resume a repeating board. Routes through
    /// `AppDatabase.setTemplateActive`, which re-reads the live row inside
    /// the write so a spawn pass or pull since the roster loaded is kept.
    private func setActive(_ tpl: RecurringBoardTemplate, _ newValue: Bool) {
        guard let userId = authService.currentUser?.id else { return }
        let now = AppDatabase.currentTimestamp()
        let templateId = tpl.id
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.setTemplateActive(
                    id: templateId, isActive: newValue, now: now
                )
                await MainActor.run { rosterVM.reloadAsync(userId: userId) }
            } catch { dlog("[BoardSettingsView] toggle active failed: \(error)") }
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
