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
///   - Muted caption: "Tasks land in your library — add them to a board in Create."
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

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                NewTaskSheetContentView(
                    userId: userId,
                    onTaskCreated: onTaskCreated,
                    onLibraryReloadRequested: onLibraryReloadRequested
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
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.risoHead(13, .extraBold))
                            .foregroundStyle(Color.risoInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.risoGold))
                            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                    }
                    .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: 999))
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
                        onLibraryReloadRequested: onLibraryReloadRequested
                    )
                }
                .padding(12)
                .risoCard(fill: .risoPaper2)
                .risoHardShadow(Riso.Shadow.small)
            }

            // Special-type panel
            VStack(alignment: .leading, spacing: 10) {
                Text("Special type")
                    .risoSectionLabel()

                RisoSpecialTaskPanel(
                    userId: userId,
                    // defaultTimeframe: nil — indefinite Tasks-tab tasks
                    defaultStartDate: nil,
                    defaultEndDate: nil,
                    taskLibrary: [],
                    onTaskCreated: { taskId, title, type in
                        onTaskCreated(taskId, title, type)
                    },
                    onCompositeCreated: { _ in
                        onLibraryReloadRequested()
                    },
                    onPendingCreated: nil,
                    onLibraryReloadRequested: onLibraryReloadRequested
                )
            }

            // Contextual note
            Text("Tasks land in your library — add them to a board in Create.")
                .font(.risoBody(12, .semibold))
                .foregroundStyle(Color.risoMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }
}
