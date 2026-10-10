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

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                NewTaskSheetContentView(
                    userId: userId,
                    onTaskCreated: onTaskCreated,
                    onLibraryReloadRequested: onLibraryReloadRequested,
                    taskLibrary: taskLibrary,
                    presetCountsTowardCounterId: presetCountsTowardCounterId
                )
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("New task")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
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
    /// Every live task of the user — the "Counts toward" candidates (the
    /// browsable `taskLibrary` hides goal-less hub counters). nil ⇒ loaded on appear.
    var countsTowardTasks: [OYBC.Task]? = nil
    @State private var loadedCountsTowardTasks: [OYBC.Task]?

    private var countsTowardPool: [OYBC.Task]? { countsTowardTasks ?? loadedCountsTowardTasks }

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
                        countsTowardTasks: countsTowardPool,
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
                    countsTowardTasks: countsTowardPool,
                    presetCountsTowardCounterId: presetCountsTowardCounterId
                )
            }
        }
        .task {
            guard countsTowardTasks == nil, loadedCountsTowardTasks == nil else { return }
            let uid = userId
            loadedCountsTowardTasks = try? await _Concurrency.Task.detached(priority: .userInitiated) {
                try AppDatabase.shared.fetchTasks(userId: uid)
            }.value
        }
        // The removed trailing caption carried the only full-width frame.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
