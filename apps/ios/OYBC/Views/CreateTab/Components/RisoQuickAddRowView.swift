import SwiftUI

/// Quick-add row for the Riso wizard Tasks step.
///
/// Text input + red "Add" button (full Riso keyline + hard-shadow).
/// Return key submits (no visible hint, per README §3 locked decisions).
/// Creates a Normal task via the existing deferred-persist creation path
/// (fires `onTaskCreated` + `onPendingCreated`) and auto-selects the
/// new task into the pool.
///
/// The row lives in the "ADD TASKS" card alongside the special-type button.
/// It owns a lightweight local `CreateFormViewModel` so it can reuse the
/// existing production validation + deferred-persist pipeline without
/// duplicating logic.
struct RisoQuickAddRowView: View {

    let userId: String
    /// Optional timeframe — nil produces an indefinite task (Tasks-tab quick-add).
    /// Wizard callers pass a real `Timeframe` value; the optional param is
    /// backward-compatible with existing call sites.
    var defaultTimeframe: Timeframe? = nil
    let defaultStartDate: String?
    let defaultEndDate: String?
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void
    let onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)?
    let onLibraryReloadRequested: () -> Void

    @State private var text: String = ""
    @State private var form = CreateFormViewModel()
    @FocusState private var focused: Bool

    private let placeholders = [
        "e.g. Meditate 10 min",
        "e.g. Drink water",
        "e.g. Read 30 min",
        "e.g. Walk the dog",
        "e.g. Stretch",
    ]
    @State private var placeholderIndex: Int = 0

    private var placeholder: String { placeholders[placeholderIndex % placeholders.count] }
    private var canSubmit: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            // Text field — keyline, paper fill, Bricolage font
            TextField(placeholder, text: $text)
                .font(.risoHead(15, .bold))
                .foregroundStyle(Color.risoInk)
                .tint(Color.risoBlue)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { submit() }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.risoPaper)
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                )

            // Add button
            RisoButton(title: "Add", kind: .primary, action: submit)
                .opacity(canSubmit ? 1 : 0.45)
                .allowsHitTesting(canSubmit)
        }
    }

    // MARK: - Submit

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Configure the form for a Normal task
        form.taskType = .normal
        form.title = trimmed

        form.handleCreateAndAddToPool(
            userId: userId,
            onTaskCreated: { taskId, title, type in
                onTaskCreated(taskId, title, type)
            },
            onLibraryReloadRequested: onLibraryReloadRequested,
            defaultTimeframe: defaultTimeframe,
            defaultStartDate: defaultStartDate,
            defaultEndDate: defaultEndDate,
            deferPersist: onPendingCreated != nil,
            onPendingCreated: onPendingCreated
        )

        // Reset immediately — the model's async path handles DB work
        text = ""
        form = CreateFormViewModel()
        placeholderIndex += 1
        focused = true
    }
}
