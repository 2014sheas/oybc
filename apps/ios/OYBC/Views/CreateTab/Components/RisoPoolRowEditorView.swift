import SwiftUI

/// Inline pool-row editor (Inline Task Editing PR 1 — simple & counting).
///
/// Replaces a resting `RisoPoolListView` row in place: an accent header bar, a
/// Title field (autofocused), the counting Action/Goal/Unit row with a live
/// "Reads as" preview, a staging hint, a validation line, and Discard / Save
/// actions. Edits are staged only — nothing touches the DB until the board is
/// created (`onSave` writes the parent's `stagedEdits`). Compound editing is
/// PR 2; this view renders `.normal` and `.counting`.
struct RisoPoolRowEditorView: View {

    let taskType: TaskType
    @Binding var draft: TaskEditPatch
    let onSave: () -> Void
    let onDiscard: () -> Void

    @FocusState private var titleFocused: Bool

    private var validationMessage: String? { draft.validate(type: taskType) }
    private var isBlocked: Bool { validationMessage != nil }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            VStack(alignment: .leading, spacing: 11) {
                titleField
                if taskType == .counting { countingFields }
                if let msg = validationMessage {
                    Text(msg)
                        .font(.risoBody(11.5, .extraBold))
                        .foregroundStyle(Color.risoRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            .padding(12)
        }
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.card)
        .onAppear { titleFocused = true }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 14, weight: .bold))
            Text(headerLabel)
                .font(.risoBody(9.5, .extraBold))
                .tracking(1.3)
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.risoPaper) // on-color: pairs with the blue fill in both themes
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.risoBlue)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.risoInk).frame(height: Riso.Keyline.container)
        }
    }

    private var headerLabel: String {
        switch taskType {
        case .counting: return "Editing · Counting task"
        case .compound: return "Editing · Compound task"
        // "Normal" is the app's domain term for this TaskType (RisoTypeBadge
        // renders .normal as "Normal") — don't paraphrase it as "Simple".
        default: return "Editing · Normal task"
        }
    }

    // MARK: - Fields

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Task title").risoSectionLabel(.risoRed)
            RisoTextField(placeholder: "Task title", text: $draft.title)
                .focused($titleFocused)
        }
    }

    private var countingFields: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                labeledField("Action", flex: true) {
                    RisoTextField(placeholder: "e.g. Run", text: $draft.action)
                }
                labeledField("Goal", width: 64) {
                    RisoNumberField(placeholder: "5", text: $draft.goal)
                }
                labeledField("Unit", flex: true) {
                    RisoTextField(placeholder: "km", text: $draft.unit)
                }
            }
            if let preview = draft.countingPreview {
                Text(preview)
                    .font(.risoBody(11.5, .bold))
                    .foregroundStyle(Color.risoBlue)
            }
        }
    }

    /// Kicker label above a field. `flex` fields expand; `width` pins a fixed
    /// width (the narrow Goal column).
    @ViewBuilder
    private func labeledField<Content: View>(
        _ label: String, flex: Bool = false, width: CGFloat? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).risoSectionLabel(.risoRed)
            content()
        }
        .frame(maxWidth: flex ? .infinity : nil)
        .frame(width: width)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 9) {
            RisoButton(title: "Discard", kind: .neutral, fullWidth: true) { onDiscard() }
            RisoButton(title: "Save task", kind: .primary, fullWidth: true) { onSave() }
                .disabled(isBlocked)
                .opacity(isBlocked ? 0.45 : 1)
        }
    }
}
