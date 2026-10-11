import SwiftUI

/// NewTaskSheetView — Riso-styled "New task" bottom sheet for the Tasks tab.
///
/// Allows the user to create multiple tasks in one session (the sheet
/// stays open after each addition). Dismiss via the Done button.
///
/// Layout top → bottom:
///   - "NEW TASK" section label + Done button
///   - Quick-add composer (`RisoQuickAddRowView`) — fast Normal tasks
///   - Special-type panel (`RisoSpecialTaskPanel`) — Counting / Compound / Achievement
///
/// Creation mode: **immediate-persist, library-only** (non-deferred).
/// Passes `onPendingCreated: nil` so writes go straight to GRDB.
/// Tasks are **indefinite** (`defaultTimeframe: nil`).
///
/// After each successful creation the panel/quick-add collapses and clears;
/// `onTaskCreated` and `onLibraryReloadRequested` fire so the Tasks-tab list
/// refreshes behind the open sheet.
struct NewTaskSheetView: View {

    let userId: String

    /// Fired when a task is created. Caller reloads the library + vm.
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void

    /// Called after any successful creation so the library can refresh.
    let onLibraryReloadRequested: () -> Void

    /// All non-deleted tasks for the authenticated user. Passed through to
    /// `RisoSpecialTaskPanel` so the counter-link suggestion can run against
    /// the full live task set. Defaults to `[]` (no suggestions shown)
    /// so callers that don't have the library yet don't need to change.
    var taskLibrary: [OYBC.Task] = []

    /// Counter Detail's "+ New": the counter the new task counts toward (preselected).
    var presetCountsTowardCounterId: String? = nil

    /// Injected database (ROADMAP B3 seam) — reads the preset counter's name.
    var database: AppDatabase = .shared

    @Environment(\.dismiss) private var dismiss

    /// The preset counter's display name (the title's `UnitTagView`); nil until loaded / without a preset.
    @State private var counterName: String?

    /// The preset counter's display name (`CounterSettings.counterDisplayName`);
    /// nil when there is no preset or the root is missing / deleted.
    static func presetCounterName(database: AppDatabase, counterId: String?) -> String? {
        guard let counterId, let root = try? database.fetchTask(id: counterId), !root.isDeleted else { return nil }
        return CounterSettings.counterDisplayName(root)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                NewTaskSheetContentView(
                    userId: userId,
                    onTaskCreated: onTaskCreated,
                    onLibraryReloadRequested: onLibraryReloadRequested,
                    taskLibrary: taskLibrary,
                    presetCountsTowardCounterId: presetCountsTowardCounterId,
                    submitLabel: CountsTowardLabels.submitLabel
                )
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .task(id: presetCountsTowardCounterId) {
                let db = database
                let id = presetCountsTowardCounterId
                let name = await _Concurrency.Task.detached(priority: .userInitiated) {
                    Self.presetCounterName(database: db, counterId: id)
                }.value
                counterName = name
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    NewTaskSheetTitle(counterName: counterName)
                }
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(title: "Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
        }
    }
}

/// The scrollable content of `NewTaskSheetView` — quick-add composer,
/// special-type panel, and the library note — without the NavigationStack
/// toolbar chrome. Extracted as a real reusable view so the sheet and the
/// snapshot tests render the SAME layout from one source of truth (not a
/// hand-mirrored copy).
struct NewTaskSheetContentView: View {

    let userId: String
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void
    let onLibraryReloadRequested: () -> Void

    /// All non-deleted tasks for the authenticated user — forwarded to
    /// `RisoSpecialTaskPanel` for the counter-link suggestion. Defaults
    /// to `[]` so snapshot tests and callers that lack the library don't
    /// break (no suggestions shown when empty).
    var taskLibrary: [OYBC.Task] = []

    /// Counter Detail's "+ New": the counter the new task counts toward (preselected).
    var presetCountsTowardCounterId: String? = nil

    /// Special-panel submit copy; the sheet passes "Add to library" for every host.
    var submitLabel: String = "Add to board ✦"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            // Quick-add composer
            VStack(alignment: .leading, spacing: 10) {
                Text("Quick add")
                    .risoSectionLabel()

                VStack(spacing: 0) {
                    RisoQuickAddRowView(
                        userId: userId,
                        // defaultTimeframe: nil — indefinite Tasks-tab tasks
                        defaultStartDate: nil,
                        defaultEndDate: nil,
                        onTaskCreated: { taskId, title, type in
                            onTaskCreated(taskId, title, type)
                        },
                        onPendingCreated: nil,
                        onLibraryReloadRequested: onLibraryReloadRequested,
                        presetCountsTowardCounterId: presetCountsTowardCounterId
                    )
                }
                .padding(12)
                .risoCard(fill: .risoPaper2)
                .risoHardShadow(Riso.Shadow.small)
            }

            // Special-type panel — receives the real task library so the
            // counter-link suggestion can fire on action+unit match.
            VStack(alignment: .leading, spacing: 10) {
                Text("Special type")
                    .risoSectionLabel()

                RisoSpecialTaskPanel(
                    userId: userId,
                    // defaultTimeframe: nil — indefinite Tasks-tab tasks
                    defaultStartDate: nil,
                    defaultEndDate: nil,
                    taskLibrary: taskLibrary,
                    onTaskCreated: { taskId, title, type in
                        onTaskCreated(taskId, title, type)
                    },
                    onCompoundCreated: { _ in
                        onLibraryReloadRequested()
                    },
                    onPendingCreated: nil,
                    onLibraryReloadRequested: onLibraryReloadRequested,
                    submitLabel: submitLabel,
                    presetCountsTowardCounterId: presetCountsTowardCounterId
                )
            }
        }
        // The removed trailing caption carried the only full-width frame.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sheet's toolbar title: "New task", plus the regular `UnitTagView` of the
/// counter when opened from Counter Detail's "+ New". Non-interactive.
struct NewTaskSheetTitle: View {
    var counterName: String?

    var body: some View {
        VStack(spacing: 5) {
            Text("New task")
                .font(.risoHead(17, .extraBold))
                .foregroundStyle(Color.risoInk)
            if let counterName {
                UnitTagView(name: counterName)
            }
        }
    }
}
