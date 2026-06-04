import SwiftUI

/// NewTaskSheetView — Modal wrapper around `CreateNewTaskFormView` for
/// use inside the board-creation wizard's Tasks step. Mirrors the web
/// `NewTaskSheet` component.
///
/// Owns its own `CreateFormViewModel` so form state resets cleanly each
/// time the sheet opens (SwiftUI re-creates the view inside `.sheet { }`).
/// On successful submission the sheet calls the parent's `onTaskCreated`
/// (or `onCompositeCreated`) and dismisses; the parent is responsible
/// for auto-selecting the new task in the wizard's selection set.
struct NewTaskSheetView: View {
    let userId: String

    /// Fired when a NORMAL/COUNTING/PROGRESS task is created. The wizard
    /// should auto-add `(taskId, title, type)` to its `selectedTaskIds`.
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void

    /// Fired when a composite task is created. The wizard typically
    /// reloads the library so the composite shows up under filters; it
    /// is NOT auto-selected because composites can't be boarded directly.
    let onCompositeCreated: (OYBC.Task) -> Void

    /// Called after either creation callback so the parent's library
    /// view-model can refresh in the same turn the sheet dismisses.
    let onLibraryReloadRequested: () -> Void

    /// Override for the form's submit button label. Wizard context wants
    /// "Create & Select" (the new task is auto-added to the pool); the
    /// Tasks-tab context wants "Add to library".
    var submitLabel: String = "Create & Select"

    /// Phase 6.Y — Timeboxed Tasks. When the sheet is mounted from the
    /// board wizard the wizard passes its currentTimeframe + resolved
    /// dates so every task created here inherits the board's window.
    /// Standalone Tasks-tab usage omits these (resulting tasks are
    /// indefinite).
    var defaultTimeframe: Timeframe? = nil
    var defaultStartDate: String? = nil
    var defaultEndDate: String? = nil

    /// Bug #85 — Deferred-persist mode. When `true`, the form builds
    /// the task fully in memory and fires `onTaskCreated` + `onPendingCreated`
    /// WITHOUT writing anything to GRDB or the sync queue. The wizard
    /// is responsible for persisting inside `persistWizardBoard`.
    /// When `false` (default), existing immediate-persist behaviour is
    /// preserved so standalone Tasks-tab quick-add is unchanged.
    var deferPersist: Bool = false

    /// Bug #85 — Called alongside `onTaskCreated` when `deferPersist == true`.
    /// Receives the full `PendingTaskPayload` so the wizard can store it for
    /// the board-save transaction. Nil in immediate-persist mode.
    var onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)? = nil

    @State private var form = CreateFormViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                CreateNewTaskFormView(
                    form: form,
                    userId: userId,
                    onSubmit: handleSubmit,
                    onCompositeCreated: { ct in
                        onCompositeCreated(ct)
                        onLibraryReloadRequested()
                        dismiss()
                    },
                    submitLabel: submitLabel
                )
                .padding(16)
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func handleSubmit() {
        form.handleCreateAndAddToPool(
            userId: userId,
            onTaskCreated: { taskId, title, type in
                onTaskCreated(taskId, title, type)
                if !deferPersist {
                    // Immediate mode: reload library after DB write.
                    onLibraryReloadRequested()
                }
                dismiss()
            },
            onLibraryReloadRequested: onLibraryReloadRequested,
            defaultTimeframe: defaultTimeframe,
            defaultStartDate: defaultStartDate,
            defaultEndDate: defaultEndDate,
            deferPersist: deferPersist,
            onPendingCreated: onPendingCreated
        )
    }
}
