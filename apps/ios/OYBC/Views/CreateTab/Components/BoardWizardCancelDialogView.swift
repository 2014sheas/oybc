import SwiftUI

/// BoardWizardCancelDialogView — Three-option prompt shown when the
/// user dismisses the wizard mid-edit. iOS twin of web's
/// `BoardWizardCancelDialog`.
///
/// Presented as a bottom sheet via `.sheet(isPresented:)`. The three
/// options mirror the web version:
/// - **Save Draft / Save Changes** (primary) — persists current state.
///   Disabled when `canSaveDraft` is false.
/// - **Discard** — drops unsaved state and closes the wizard.
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

                Button(action: onKeepEditing) {
                    Text("Keep Editing")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
    }
}
