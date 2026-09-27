import SwiftUI

/// "Repeat this board" sheet (Board Edit redesign slice 2, D6 —
/// docs/BOARD_EDIT_REDESIGN.md, OQ5). Reuses the staged REPEATS logic moved
/// verbatim out of `BoardEditPanel.repeatsSection` — only the chrome changed
/// (its own Cancel · "Repeat this board" · Save, instead of living inside
/// the squares editor's scroll content).
///
/// Two variants, matching the old panel section exactly:
///   - `sourceTemplate != nil` (a REPEATING board with a resolved source
///     record): the cadence-adverb note + Repeating/Paused toggle.
///   - `sourceTemplate == nil` (a one-off board): the Off/Daily/Weekly/
///     Monthly/Yearly cadence picker. `BoardMenuItems.isRepeatEligible`
///     already hid the menu item for a CHOSEN-center one-off or an
///     unresolved repeating record, so this view doesn't re-guard either.
struct BoardRepeatSheetView: View {

    let board: Board
    /// The board's resolved source repeating record, or nil for a one-off
    /// board. See `BoardPlayViewModel.editSourceTemplate`.
    let sourceTemplate: RecurringBoardTemplate?
    /// Read-only spawn-provenance note for the repeating-board variant,
    /// resolved off-main only while this sheet is open
    /// (`BoardPlayViewModel.loadSpawnNote()`). Nil hides the line.
    var spawnNoteProvider: () async -> String? = { nil }
    /// Commits the staged intent. Throws `BoardEditError.boardNotEditable`
    /// for a board sealed/deleted since the sheet opened.
    let onSave: (BoardPlayViewModel.EditRepeatIntent) async throws -> Void
    let onDismiss: () -> Void

    @State private var repeatActive: Bool
    @State private var repeatCadence: Timeframe?
    @State private var spawnNoteText: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        board: Board,
        sourceTemplate: RecurringBoardTemplate?,
        spawnNoteProvider: @escaping () async -> String? = { nil },
        onSave: @escaping (BoardPlayViewModel.EditRepeatIntent) async throws -> Void,
        onDismiss: @escaping () -> Void,
        // Snapshot-test-only seeds for a STAGED (not clean) initial render —
        // production call sites never pass these, so every existing behavior
        // (seed from the live record) is unchanged.
        initialCadence: Timeframe? = nil,
        initialRepeatActive: Bool? = nil
    ) {
        self.board = board
        self.sourceTemplate = sourceTemplate
        self.spawnNoteProvider = spawnNoteProvider
        self.onSave = onSave
        self.onDismiss = onDismiss
        _repeatActive = State(initialValue: initialRepeatActive ?? sourceTemplate?.isActive ?? true)
        _repeatCadence = State(initialValue: initialCadence)
    }

    /// Staged cadence options for the one-off variant — Off (default) plus
    /// the four cadences, moved verbatim from `BoardEditPanel`.
    private static let repeatCadenceOptions: [(value: Timeframe?, label: String)] = [
        (nil, "Off"),
        (.daily, "Daily"),
        (.weekly, "Weekly"),
        (.monthly, "Monthly"),
        (.yearly, "Yearly"),
    ]

    private var isDirty: Bool {
        if let template = sourceTemplate { return repeatActive != template.isActive }
        return repeatCadence != nil
    }

    private var canSave: Bool { isDirty && !isSaving }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    content
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.risoBody(12, .semibold))
                            .foregroundStyle(Color.risoRed)
                    }
                }
                .padding(.horizontal, Riso.gutter)
                .padding(.vertical, 16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Repeat this board")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(title: isSaving ? "Saving…" : "Save") { save() }
                        .disabled(!canSave)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .disabled(isSaving)
                }
            }
        }
        .task {
            spawnNoteText = await spawnNoteProvider()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let template = sourceTemplate {
            Text("↻ Repeats \(formatCadenceAdverb(template.timeframe)) · from \"\(template.name)\"")
                .font(.risoBody(12.5, .semibold))
                .foregroundStyle(Color.risoInk)
                .fixedSize(horizontal: false, vertical: true)
            RisoSegmented(
                options: [(true, "Repeating"), (false, "Paused")],
                selection: $repeatActive
            )
            if let spawnNoteText {
                Text(spawnNoteText)
                    .font(.risoBody(11.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            RisoSegmented(
                options: Self.repeatCadenceOptions,
                selection: $repeatCadence
            )
            if repeatCadence != nil {
                Text("This becomes a repeating board when you save.")
                    .font(.risoBody(12, .regular))
                    .foregroundStyle(Color.risoMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func save() {
        guard isDirty else { onDismiss(); return }
        let intent: BoardPlayViewModel.EditRepeatIntent
        if let template = sourceTemplate {
            intent = .setActive(template: template, isActive: repeatActive)
        } else if let cadence = repeatCadence {
            intent = .startRepeating(cadence: cadence)
        } else {
            onDismiss()
            return
        }
        isSaving = true
        errorMessage = nil
        _Concurrency.Task { @MainActor in
            do {
                try await onSave(intent)
                isSaving = false
                onDismiss()
            } catch BoardEditError.boardNotEditable {
                isSaving = false
                onDismiss()
            } catch {
                isSaving = false
                errorMessage = "Couldn’t save your changes — please try again."
            }
        }
    }
}
