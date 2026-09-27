import Foundation

/// The staged "Board details" form (Board Edit redesign slice 2, D4/D5/D12 —
/// docs/BOARD_EDIT_REDESIGN.md). Pure value type: seeded from a board, edited
/// by the sheet's bindings, and turned into ONE `UpdateActiveBoardPatch` on
/// Save. Twin of web `components/boardActions/boardDetailsPatch.ts`.
///
/// The date branch moved here from `BoardPlayViewModel.handleEditSave`
/// (slice 1), with the D12 fix: an ongoing board's start-date edit is now
/// saved (it used to be counted but dropped), and Custom → Ongoing keeps the
/// picked start instead of re-anchoring to today. Under Windowed Completion
/// `startDate` is the window's lower bound, so a silent re-anchor wipes every
/// earlier completion.
///
/// Timeframe never switches after creation — the ONLY switch is Custom ⇄
/// Ongoing (the End date's "None — no end date" choice). Calendar timeframes
/// have no date edits at all.
struct BoardDetailsDraft {

    /// The board as it was when the sheet opened (the diff baseline).
    let board: Board

    var name: String
    /// Only `.custom` ⇄ `.indefinite` is honoured; any other value is ignored.
    var timeframe: Timeframe
    var startDate: Date
    var endDate: Date
    var centerType: CenterSquareType

    let originalStartDate: Date
    let originalEndDate: Date

    /// Date-picker changes below this are picker noise, not an edit.
    static let dateToleranceSeconds: TimeInterval = 60

    /// Seeds the draft from `board`.
    ///
    /// - Parameters:
    ///   - board: The board being edited.
    ///   - now: Clock for the fallback dates (a missing end date seeds
    ///     `startOfDay(now) + 30 days` so the picker has a sensible value if
    ///     the user converts Ongoing → Custom).
    init(board: Board, now: Date = Date()) {
        self.board = board
        name = board.name
        timeframe = board.timeframe
        centerType = board.centerSquareType
        let cal = Calendar.current
        let fallbackStart = cal.startOfDay(for: now)
        let seedStart = Self.parseBoardDate(board.startDate) ?? fallbackStart
        let seedEnd = board.endDate.flatMap(Self.parseBoardDate)
            ?? cal.date(byAdding: .day, value: 30, to: cal.startOfDay(for: seedStart))
            ?? seedStart
        startDate = seedStart
        endDate = seedEnd
        originalStartDate = seedStart
        originalEndDate = seedEnd
    }

    // MARK: - Change groups

    /// True for the two timeframes whose dates the user picks.
    private static func hasUserDates(_ tf: Timeframe) -> Bool {
        tf == .custom || tf == .indefinite
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// The timeframe Save would write: the draft's, but only for a
    /// Custom ⇄ Ongoing switch; anything else keeps the board's.
    var effectiveTimeframe: Timeframe {
        Self.hasUserDates(board.timeframe) && Self.hasUserDates(timeframe)
            ? timeframe : board.timeframe
    }

    private var nameChanged: Bool { trimmedName != board.name }
    private var timeframeChanged: Bool { effectiveTimeframe != board.timeframe }
    private var startChanged: Bool {
        abs(startDate.timeIntervalSince(originalStartDate)) > Self.dateToleranceSeconds
    }
    private var endChanged: Bool {
        abs(endDate.timeIntervalSince(originalEndDate)) > Self.dateToleranceSeconds
    }

    /// The "dates" edit group: a Custom ⇄ Ongoing switch, an ongoing start
    /// edit, or a custom start/end edit. Calendar timeframes never count.
    private var datesChanged: Bool {
        guard Self.hasUserDates(board.timeframe) else { return false }
        if timeframeChanged { return true }
        if effectiveTimeframe == .indefinite { return startChanged }
        return startChanged || endChanged
    }

    private var centerChanged: Bool { centerType != board.centerSquareType }

    /// Edit count, one per group (name / dates / center). Counts exactly what
    /// `patch()` would write, so the badge and the save can't disagree.
    var editCount: Int {
        [nameChanged, datesChanged, centerChanged].filter { $0 }.count
    }

    var isDirty: Bool { editCount > 0 }

    // MARK: - Validation

    /// The first validation failure, or nil when the draft can save. Copy is
    /// shared with web's `validateBoardDetails`.
    ///
    /// - Parameter hasCandidateTasks: Whether the board has any placement that
    ///   could back a CHOSEN center.
    /// - Returns: A user-facing message, or nil when valid.
    func validationError(hasCandidateTasks: Bool) -> String? {
        if trimmedName.isEmpty { return "Board name is required." }
        if effectiveTimeframe == .custom,
           Self.snapEnd(endDate) < Self.snapStart(startDate) {
            return "End date must be on or after the start date."
        }
        if centerType == .chosen, board.centerTaskId == nil || !hasCandidateTasks {
            return "CHOSEN is unavailable — this board has no existing center task to restore."
        }
        return nil
    }

    // MARK: - Patch

    /// The metadata patch Save commits, or nil when nothing changed. Fields
    /// left nil are "leave unchanged" — in particular a save that doesn't
    /// touch the dates omits both, preserving the stored window.
    ///
    /// Callers validate first (`validationError`); this does not re-validate.
    ///
    /// - Returns: The patch, or nil when the draft is clean.
    func patch() -> AppDatabase.UpdateActiveBoardPatch? {
        guard isDirty else { return nil }
        var patch = AppDatabase.UpdateActiveBoardPatch()
        if nameChanged { patch.name = trimmedName }
        if centerChanged { patch.centerSquareType = centerType }
        guard datesChanged else { return patch }
        if timeframeChanged { patch.timeframe = effectiveTimeframe }
        patch.startDate = Self.snapStart(startDate)
        if effectiveTimeframe == .indefinite {
            // Custom → Ongoing clears the deadline; an ongoing start edit
            // leaves the (already nil) end alone.
            patch.clearEndDate = timeframeChanged
        } else {
            patch.endDate = Self.snapEnd(endDate)
        }
        return patch
    }

    // MARK: - Date helpers

    /// Local-ISO start of `d`'s day (`…T00:00:00.000`).
    static func snapStart(_ d: Date) -> String {
        wizardLocalISOString(Calendar.current.startOfDay(for: d))
    }

    /// Local-ISO last millisecond of `d`'s day (`…T23:59:59.999`).
    static func snapEnd(_ d: Date) -> String {
        let cal = Calendar.current
        let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d))!
        return wizardLocalISOString(nextDay.addingTimeInterval(-0.001))
    }

    /// Parses a stored board date (full local/UTC ISO, or a bare
    /// `yyyy-MM-dd`). The slice-1 seed used `parseWizardCalendarDate` alone,
    /// which rejects full ISO strings, so every board seeded "today".
    private static func parseBoardDate(_ s: String) -> Date? {
        parseISO8601Date(s) ?? parseWizardCalendarDate(s)
    }
}
