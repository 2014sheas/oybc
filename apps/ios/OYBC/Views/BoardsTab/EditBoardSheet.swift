import SwiftUI

// MARK: - EditBoardSheet

/// Sheet for editing metadata on an ACTIVE board (M2, #89).
///
/// Wraps `BoardSetupFormView` in `.editActive` mode, pre-filling all
/// controls from the loaded board. On "Save" the changes are written via
/// `AppDatabase.shared.updateBoardAndCascade`.
///
/// Editable fields: name, timeframe, custom dates, center type,
///   custom center name.
/// Immutable on active boards: board size (shown as a read-only Riso chip),
///   isCore, spawnedFromTemplateId, isRandomized.
///
/// Center-switch semantics (spec §5 of M2):
///   - CHOSEN → FREE/CUSTOM_FREE: preserves the underlying BoardTask row;
///     the cell will render as FREE on top of the placement.
///   - FREE/CUSTOM_FREE → CHOSEN: disabled when no candidate tasks exist
///     in boardTasks for this board.
///   - Anything → NONE: same preserve-placement rule.
///
/// Date handling: start date is snapped to local start-of-day and end date
/// to end-of-day (23:59:59.999) via `wizardLocalISOString` — mirrors the
/// web `snapStart`/`snapEnd` helpers so the calendar window covers the
/// whole day in the user's timezone.
///
/// Visual design: Riso vocabulary — ScrollView over `Color.risoPaper`,
/// NavigationStack toolbar with a gold-pill Save button and a muted Cancel.
/// The immutable-size chip and form sections use `.risoCard` blocks.
struct EditBoardSheet: View {
    let board: Board
    let weekStartDay: String
    let onSaved: () -> Void

    @EnvironmentObject var authService: AuthService

    // MARK: - State

    @State private var name: String = ""
    @State private var timeframe: Timeframe = .monthly
    @State private var customStartDate: Date = Date()
    @State private var customEndDate: Date = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var centerType: CenterSquareType = .free
    @State private var centerCustomName: String = ""

    // Guard for CHOSEN: CHOSEN is only available when the board already has a
    // centerTaskId (previously created with a chosen center AND the placement
    // still exists). The sheet has no mechanism to collect a new centerTaskId,
    // so FREE → CHOSEN with centerTaskId == nil would persist invalid state.
    @State private var hasCandidateTasks: Bool = false

    @State private var saving: Bool = false
    @State private var validationError: String? = nil

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // ── Immutable board-size chip ──────────────────────────
                    sizeChip

                    // ── Validation error ───────────────────────────────────
                    if let err = validationError {
                        Text(err)
                            .font(.risoBody(13, .semibold))
                            .foregroundStyle(Color.risoRed)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .risoCard(fill: .risoPaper2)
                    }

                    // ── Editable setup form ────────────────────────────────
                    BoardSetupFormView(
                        mode: .editActive,
                        name: $name,
                        timeframe: $timeframe,
                        customStartDate: $customStartDate,
                        customEndDate: $customEndDate,
                        centerType: $centerType,
                        centerCustomName: $centerCustomName,
                        weekStartDay: weekStartDay,
                        chosenCenterDisabled: board.centerTaskId == nil || !hasCandidateTasks
                    )
                }
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Edit board")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(title: saving ? "Saving…" : "Save") { handleSave() }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { seedState() }
        }
    }

    // MARK: - Immutable size chip

    /// Riso-styled read-only board-size chip displayed above the editable
    /// form fields to remind the user that size is locked on active boards.
    private var sizeChip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Board size")
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

    // MARK: - Seed

    /// Pre-fill all form controls from the live board record.
    private func seedState() {
        name = board.name
        timeframe = board.timeframe
        if let s = parseWizardCalendarDate(board.startDate) { customStartDate = s }
        if let e = parseWizardCalendarDate(board.endDate) { customEndDate = e }
        centerType = board.centerSquareType
        centerCustomName = board.centerSquareCustomName ?? ""

        // Load board tasks to determine if CHOSEN is available.
        _Concurrency.Task.detached(priority: .userInitiated) {
            let count = (try? AppDatabase.shared.fetchBoardTasks(boardId: board.id).count) ?? 0
            await MainActor.run { hasCandidateTasks = count > 0 }
        }
    }

    // MARK: - Save

    private func handleSave() {
        validationError = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "Board name is required."
            return
        }
        // CHOSEN is only valid when the board already has a centerTaskId.
        // The sheet has no mechanism to select a new center task, so
        // FREE → CHOSEN with centerTaskId == nil would persist invalid state
        // (violates the shared Zod invariant: CHOSEN requires centerTaskId).
        if centerType == .chosen && (board.centerTaskId == nil || !hasCandidateTasks) {
            validationError = "CHOSEN is unavailable — this board has no existing center task to restore."
            return
        }

        // Resolve dates: snap to local start/end of day using the same
        // helper as the wizard so calendar windows are consistent.
        let cal = Calendar.current

        func snapStart(_ d: Date) -> String {
            wizardLocalISOString(cal.startOfDay(for: d))
        }
        func snapEnd(_ d: Date) -> String {
            let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d))!
            return wizardLocalISOString(nextDay.addingTimeInterval(-0.001))
        }

        let startISO: String
        let endISO: String

        if timeframe == .custom {
            startISO = snapStart(customStartDate)
            endISO = snapEnd(customEndDate)
            // Validate ordering.
            if endISO < startISO {
                validationError = "End date must be on or after the start date."
                return
            }
        } else if let boundaries = computeTimeframeBoundaries(
            timeframe: timeframe,
            referenceDate: Date(),
            weekStartDay: weekStartDay
        ) {
            startISO = wizardLocalISOString(boundaries.start)
            endISO = wizardLocalISOString(boundaries.end)
        } else {
            validationError = "Could not compute timeframe boundaries."
            return
        }

        let patch = AppDatabase.UpdateActiveBoardPatch(
            name: trimmedName,
            timeframe: timeframe,
            startDate: startISO,
            endDate: endISO,
            centerSquareType: centerType,
            centerSquareCustomName: centerType == .customFree
                ? (centerCustomName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : centerCustomName.trimmingCharacters(in: .whitespaces))
                : nil
            // centerTaskId: not collected here — existing value preserved by the write helper for CHOSEN,
            // cleared for other types (see AppDatabase.updateBoardAndCascade).
        )

        saving = true
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                try AppDatabase.shared.updateBoardAndCascade(boardId: board.id, patch: patch)
                await MainActor.run {
                    saving = false
                    onSaved()
                    dismiss()
                }
            } catch {
                print("⚠️ EditBoardSheet: save failed — \(error)")
                await MainActor.run {
                    saving = false
                    validationError = "Save failed — please try again."
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let json = """
    {"id":"preview-board","userId":"u1","name":"Spring Goals","status":"active","boardSize":3,"timeframe":"monthly","startDate":"2026-05-01T00:00:00.000","endDate":"2026-05-31T23:59:59.999","centerSquareType":"free","isRandomized":true,"totalTasks":9,"completedTasks":4,"linesCompleted":1,"createdAt":"2026-05-01T00:00:00.000","updatedAt":"2026-05-15T12:00:00.000","version":3,"isDeleted":false}
    """
    let board = try! JSONDecoder().decode(Board.self, from: json.data(using: .utf8)!)
    EditBoardSheet(board: board, weekStartDay: "monday", onSaved: {})
        .environmentObject(AuthService())
}
