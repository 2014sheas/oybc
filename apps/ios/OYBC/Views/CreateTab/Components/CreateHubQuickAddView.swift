import SwiftUI

/// CreateHubQuickAddView — Inline task-creation surface on the Create
/// Hub. Wraps the existing `CreateNewTaskFormView` to preserve every
/// validation rule and per-type field behaviour from the legacy
/// Create tab; new tasks land in the user's library only. Composites
/// are fully supported because `CreateNewTaskFormView` delegates to
/// `CompositeTaskFormView` when the composite type is picked.
///
/// iOS twin of web's `CreateHubQuickAdd`.
struct CreateHubQuickAddView: View {
    let userId: String
    /// Called after every successful task / composite creation so the
    /// hub can reload the library count (and surface a fresh toast).
    let onTaskCreated: () -> Void

    @State private var form = CreateFormViewModel()
    @State private var successMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUICK-ADD TASK")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)

            Text("Add a task straight to your library — you can put it on a board later.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let msg = successMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
                    .transition(.opacity)
            }

            CreateNewTaskFormView(
                form: form,
                userId: userId,
                onSubmit: handleSubmit,
                onCompositeCreated: handleCompositeCreated,
                submitLabel: "Add to library"
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color(.systemGray4), lineWidth: 1)
                )
        )
    }

    private func handleSubmit() {
        form.handleCreateAndAddToPool(
            userId: userId,
            onTaskCreated: { _, title, _ in
                flashSuccess("Added \"\(title)\" to your library.")
                onTaskCreated()
            },
            onLibraryReloadRequested: {
                onTaskCreated()
            }
        )
    }

    private func handleCompositeCreated(_ ct: CompositeTask) {
        flashSuccess("Added composite \"\(ct.title)\" to your library.")
        onTaskCreated()
    }

    private func flashSuccess(_ message: String) {
        successMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if successMessage == message { successMessage = nil }
        }
    }
}
