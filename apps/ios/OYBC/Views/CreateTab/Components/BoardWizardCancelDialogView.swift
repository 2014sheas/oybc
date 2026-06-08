import SwiftUI

/// BoardWizardCancelDialogView — Prompt shown when the user dismisses
/// the wizard mid-edit. iOS twin of web's `BoardWizardCancelDialog`.
///
/// Presented as a bottom sheet via `.sheet(isPresented:)`. Options
/// mirror the web version:
/// - **Save Draft / Save Changes** (primary) — persists current state.
///   Disabled when `canSaveDraft` is false.
/// - **Discard** — drops unsaved state and closes the wizard.
/// - **Delete draft** (conditional) — only present when resuming an
///   existing draft. Drops the persisted draft + its placements via
///   `deleteDraftWithCascade`, behind a confirmation alert.
/// - **Keep Editing** — dismisses the sheet.
struct BoardWizardCancelDialogView: View {
    /// Disables the Save-Draft button when false (typically because
    /// Step 1 isn't valid enough to produce a well-formed Board record).
    let canSaveDraft: Bool
    /// Tooltip-style reason shown under the disabled button.
    let saveDraftBlockedReason: String?
    /// Primary-action label. Defaults to "Save Draft"; set to
    /// "Save Changes" when resuming an existing draft.
    let saveDraftLabel: String

    let onSaveDraft: () -> Void
    let onDiscard: () -> Void
    let onKeepEditing: () -> Void
    /// Optional destructive action — only present when the wizard is
    /// resuming an existing draft. When non-nil, a "Delete draft"
    /// button appears between Discard and Keep Editing, behind a
    /// confirmation `Alert`.
    var onDeleteDraft: (() -> Void)? = nil

    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Close this board?")
                    .font(.headline)
                Text("You've made changes that haven't been saved yet. What would you like to do?")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                Button(action: onSaveDraft) {
                    Text(saveDraftLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveDraft)

                if !canSaveDraft, let reason = saveDraftBlockedReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(role: .destructive, action: onDiscard) {
                    Text("Discard")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                if onDeleteDraft != nil {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("Delete draft")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

                Button(action: onKeepEditing) {
                    Text("Keep Editing")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .alert("Delete this draft?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDeleteDraft?()
            }
        } message: {
            Text("The placed tasks will be removed from the board. The underlying tasks stay in your library. This can’t be undone.")
        }
    }
}
