import SwiftUI

/// BoardWizardCancelDialogView — Riso-styled exit-confirm shown when the
/// user dismisses the wizard mid-edit. iOS twin of web's
/// `BoardWizardCancelDialog`.
///
/// Presented as a bottom sheet via `.sheet(isPresented:)`. Options mirror
/// the web version:
/// - **Save Draft / Save Changes** (primary) — persists current state.
///   Disabled when `canSaveDraft` is false. Uses `RisoButton(.neutral)`.
/// - **Discard** — drops unsaved state and closes the wizard.
///   Uses `RisoButton(.primary)` (red = destructive read in Riso ink
///   vocabulary, matching the sign-out and task-delete patterns).
/// - **Delete draft** (conditional) — only present when resuming an
///   existing draft. Uses `RisoButton(.primary)` behind a confirmation
///   alert.
/// - **Keep Editing** — dismisses the sheet. Uses `RisoButton(.neutral)`.
///
/// Card: paper2 fill + solid ink keyline, matching `ProfileView`'s
/// sign-out confirm and `TaskDeleteConfirmView`. Callbacks preserved
/// verbatim from the pre-Riso version.
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
        VStack(alignment: .leading, spacing: 20) {
            // Heading
            VStack(alignment: .leading, spacing: 6) {
                Text("Close this board?")
                    .font(.risoHead(18, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Text("You've made changes that haven't been saved yet.")
                    .font(.risoBody(13, .medium))
                    .foregroundStyle(Color.risoMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action stack
            VStack(spacing: 10) {
                // Save Draft / Save Changes
                saveDraftButton

                if !canSaveDraft, let reason = saveDraftBlockedReason {
                    Text(reason)
                        .font(.risoBody(11, .regular))
                        .foregroundStyle(Color.risoRed)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Discard — red (destructive)
                RisoButton(title: "Discard", kind: .primary, fullWidth: true, action: onDiscard)

                // Delete draft — only when resuming an existing draft
                if onDeleteDraft != nil {
                    RisoButton(title: "Delete draft", kind: .primary, fullWidth: true) {
                        showDeleteConfirm = true
                    }
                }

                // Keep Editing — neutral
                RisoButton(title: "Keep Editing", kind: .neutral, fullWidth: true, action: onKeepEditing)
            }
        }
        .padding(Riso.gutter)
        .alert("Delete this draft?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDeleteDraft?()
            }
        } message: {
            Text("The placed tasks will be removed from the board. The underlying tasks stay in your library. This can't be undone.")
        }
    }

    // MARK: - Save-draft button

    /// Save Draft / Save Changes button — disabled state is styled with
    /// muted opacity rather than the default system grey so it stays
    /// visually consistent with the Riso ink treatment.
    @ViewBuilder
    private var saveDraftButton: some View {
        // Use `RisoButton` for the enabled path (gets press shadow).
        // The disabled path renders identically but without the shadow.
        if canSaveDraft {
            RisoButton(title: saveDraftLabel, kind: .neutral, fullWidth: true, action: onSaveDraft)
                .accessibilityLabel(saveDraftLabel)
        } else {
            Text(saveDraftLabel)
                .font(.risoHead(15, .bold))
                .foregroundStyle(Color.risoMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 18)
                .risoCard(fill: .risoPaper2)
                .opacity(0.45)
                .accessibilityLabel(saveDraftLabel)
        }
    }
}
