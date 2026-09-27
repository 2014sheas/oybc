import SwiftUI

/// "Board details" sheet (Board Edit redesign slice 2, D4/D5 —
/// docs/BOARD_EDIT_REDESIGN.md, handoff frame i12). Opened from the board
/// title row's "…" menu for an ad-hoc, editable board — commits
/// independently of the squares editor via `BoardDetailsDraft` +
/// `AppDatabase.saveBoardDetails`.
///
/// Layout: Cancel · "Board details" · Save toolbar pill, then the immutable
/// size chip + `BoardSetupFormView` (name · timeframe read-only note or
/// custom/ongoing dates). No REPEATS, no Archive — those moved to their own
/// menu items (`BoardRepeatSheetView`, the Archive confirm). No center
/// selector either (slice 3, D6) — the center changes only in the squares
/// editor.
struct BoardDetailsSheetView: View {

    let board: Board
    let weekStartDay: String
    /// Commits the patch. Throws `BoardEditError.boardNotEditable` for a
    /// board sealed/deleted since the sheet opened (D11).
    let onSave: (AppDatabase.UpdateActiveBoardPatch) async throws -> Void
    /// Called to close the sheet — on a successful save, a clean Cancel, a
    /// confirmed Discard, or a `boardClosed` failure (nothing left to save).
    let onDismiss: () -> Void

    @State private var draft: BoardDetailsDraft
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDiscardConfirm = false

    init(
        board: Board,
        weekStartDay: String,
        onSave: @escaping (AppDatabase.UpdateActiveBoardPatch) async throws -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.board = board
        self.weekStartDay = weekStartDay
        self.onSave = onSave
        self.onDismiss = onDismiss
        _draft = State(initialValue: BoardDetailsDraft(board: board))
    }

    private var canSave: Bool {
        draft.isDirty
            && draft.validationError() == nil
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sizeChip
                    BoardSetupFormView(
                        name: $draft.name,
                        timeframe: $draft.timeframe,
                        customStartDate: $draft.startDate,
                        customEndDate: $draft.endDate,
                        weekStartDay: weekStartDay,
                        storedWindow: storedWindow
                    )
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
                    Text("Board details")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(title: isSaving ? "Saving…" : "Save") { save() }
                        .disabled(!canSave)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { handleCancel() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .disabled(isSaving)
                }
            }
            .alert("Discard changes?", isPresented: $showDiscardConfirm) {
                Button("Keep editing", role: .cancel) {}
                Button("Discard", role: .destructive) { onDismiss() }
            } message: {
                Text("Your unsaved changes will be lost.")
            }
        }
    }

    /// The board's own stored window, for a calendar timeframe's read-only
    /// note (never the window containing today — the board's dates don't move).
    private var storedWindow: (start: Date, end: Date)? {
        guard let start = parseISO8601Date(board.startDate),
              let endStr = board.endDate, let end = parseISO8601Date(endStr)
        else { return nil }
        return (start, end)
    }

    /// Read-only board-size chip — moved here from `BoardEditPanel` (slice 2).
    private var sizeChip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BOARD SIZE")
                .risoSectionLabel()
            HStack(spacing: 10) {
                Text("\(board.boardSize)×\(board.boardSize)")
                    .font(.risoHead(16, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                Text("Immutable")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.risoPaper))
                    .overlay(Capsule().strokeBorder(Color.risoMuted, lineWidth: Riso.Keyline.dense))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .risoCard(fill: .risoPaper2)
            Text("Board size cannot be changed on an active board.")
                .font(.risoBody(11, .semibold))
                .foregroundStyle(Color.risoMuted)
        }
    }

    private func handleCancel() {
        if draft.isDirty {
            showDiscardConfirm = true
        } else {
            onDismiss()
        }
    }

    private func save() {
        if let err = draft.validationError() {
            errorMessage = err
            return
        }
        guard let patch = draft.patch() else {
            onDismiss()
            return
        }
        isSaving = true
        errorMessage = nil
        _Concurrency.Task { @MainActor in
            do {
                try await onSave(patch)
                isSaving = false
                onDismiss()
            } catch BoardEditError.boardNotEditable {
                // Slice 2 (D11) — the board closed since the sheet opened;
                // there's nothing left to save, so close the sheet too.
                isSaving = false
                onDismiss()
            } catch {
                isSaving = false
                errorMessage = "Couldn’t save your changes — please try again."
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let json = """
    {"id":"preview-board","userId":"u1","name":"Spring Goals","status":"active","boardSize":3,"timeframe":"custom","startDate":"2026-05-01T00:00:00.000","endDate":"2026-05-31T23:59:59.999","centerSquareType":"free","isRandomized":true,"totalTasks":9,"completedTasks":4,"linesCompleted":1,"createdAt":"2026-05-01T00:00:00.000","updatedAt":"2026-05-15T12:00:00.000","version":3,"isDeleted":false}
    """
    let board = try! JSONDecoder().decode(Board.self, from: json.data(using: .utf8)!)
    return BoardDetailsSheetView(
        board: board,
        weekStartDay: "monday",
        onSave: { _ in },
        onDismiss: {}
    )
}
