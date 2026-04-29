import Foundation
import Observation

/// A wizard step. 1 = Setup, 2 = Tasks, 3 = Preview & Activate.
typealias WizardStep = Int

/// Returns the number of pool tasks the chosen geometry requires.
/// Mirrors web's `tasksNeededFor` in `useBoardWizard.ts`.
///
/// - Even-sized boards (no center concept): `size²`.
/// - Odd-sized boards with FREE / CUSTOM_FREE center: `size² - 1`.
/// - Odd-sized boards with NONE: `size²`.
/// - Odd-sized boards with CHOSEN: `size²` (one selection IS the center).
func tasksNeededForBoard(size: Int, centerType: CenterSquareType) -> Int {
    let isOdd = size % 2 != 0
    let hasReservedCenter = isOdd && (centerType == .free || centerType == .customFree)
    return size * size - (hasReservedCenter ? 1 : 0)
}

/// BoardWizardViewModel — Owns the full board-creation wizard state.
///
/// iOS twin of web's `useBoardWizard` hook. Initializes from the
/// supplied `UserPreferences` snapshot at construction time; later
/// preference changes do NOT stomp in-progress wizard state. All
/// step views are fully controlled — they read fields off this model
/// and call its mutators / nav actions.
///
/// Validation is exposed as computed properties (`isStep1Valid`,
/// `isStep2Valid`) so each step can disable its own Next button
/// without re-implementing the count-needed math.
@Observable
final class BoardWizardViewModel {

    // MARK: - Step 1 fields

    var name: String = ""
    var size: Int
    var timeframe: Timeframe
    /// `yyyy-MM-dd` — empty when not yet picked.
    var customStartDate: String = ""
    /// `yyyy-MM-dd` — empty when not yet picked.
    var customEndDate: String = ""
    var centerType: CenterSquareType
    var centerCustomName: String
    var isRandomized: Bool
    let weekStartDay: String

    // MARK: - Step 2 fields

    var selectedTaskIds: Set<String> = []
    var centerTaskId: String? = nil

    // MARK: - Wizard navigation

    var currentStep: WizardStep = 1

    /// Set when the wizard was hydrated from an existing draft board.
    /// Non-nil means Save / Activate will update this record rather
    /// than create a new one.
    let draftBoardId: String?

    // MARK: - Init

    private let initialPreferences: UserPreferences

    init(
        preferences: UserPreferences,
        initialStep: WizardStep = 1,
        draft: (board: Board, boardTasks: [BoardTask])? = nil
    ) {
        self.initialPreferences = preferences
        self.weekStartDay = preferences.weekStartDay.rawValue
        self.currentStep = initialStep
        self.draftBoardId = draft?.board.id

        if let d = draft {
            self.name = d.board.name
            self.size = d.board.boardSize
            self.timeframe = d.board.timeframe
            self.centerType = d.board.centerSquareType
            self.centerCustomName = d.board.centerSquareCustomName ?? ""
            self.centerTaskId = d.board.centerTaskId
            self.isRandomized = d.board.isRandomized
            self.selectedTaskIds = Set(d.boardTasks.map { $0.taskId })
            if d.board.timeframe == .custom {
                self.customStartDate = String(d.board.startDate.prefix(10))
                self.customEndDate = String(d.board.endDate.prefix(10))
            }
        } else {
            let initialSize = preferences.defaultBoardSize.rawValue
            self.size = initialSize
            self.timeframe = Self.resolveTimeframe(preferences.defaultTimeframe)
            self.centerType = Self.coerceCenterType(
                size: initialSize,
                desired: Self.resolveCenterType(preferences.defaultCenterType)
            )
            self.centerCustomName = preferences.defaultCenterCustomName
            self.isRandomized = preferences.defaultRandomize
        }
    }

    private static func resolveCenterType(_ value: DefaultCenterSquareType) -> CenterSquareType {
        switch value {
        case .free: return .free
        case .none: return .none
        }
    }

    /// Returns a `centerType` consistent with `size`. Even boards have
    /// no center concept — the form hides the center selector for
    /// them, so a leaked FREE/CUSTOM_FREE from prefs would be
    /// unfixable from the UI. Coerce to NONE in that case. Mirrors
    /// the web `coerceCenterType` helper in `useBoardWizard.ts` and
    /// the existing odd/even guard inside `updateSize`.
    private static func coerceCenterType(
        size: Int,
        desired: CenterSquareType
    ) -> CenterSquareType {
        let isOdd = size % 2 != 0
        if !isOdd { return .none }
        return desired
    }

    private static func resolveTimeframe(_ value: DefaultTimeframe) -> Timeframe {
        switch value {
        case .daily:   return .daily
        case .weekly:  return .weekly
        case .monthly: return .monthly
        case .yearly:  return .yearly
        case .custom:  return .custom
        }
    }

    // MARK: - Coupled mutators

    /// Changes board size and resets center type when crossing the
    /// odd/even boundary so the model stays consistent.
    func updateSize(_ s: Int) {
        size = s
        let newIsOdd = s % 2 != 0
        if !newIsOdd {
            centerType = .none
            centerTaskId = nil
        } else if centerType == .none {
            centerType = .free
        }
    }

    /// Changes the center type and clears the chosen-task mark when
    /// switching away from CHOSEN.
    func updateCenterType(_ t: CenterSquareType) {
        centerType = t
        if t != .chosen {
            centerTaskId = nil
        }
    }

    /// Toggles a task's selection; clears the center mark if the user
    /// is deselecting the current center.
    func toggleTaskSelection(_ taskId: String) {
        if selectedTaskIds.contains(taskId) {
            selectedTaskIds.remove(taskId)
            if centerTaskId == taskId { centerTaskId = nil }
        } else {
            selectedTaskIds.insert(taskId)
        }
    }

    func setCenterTaskId(_ id: String?) {
        centerTaskId = id
    }

    // MARK: - Step navigation

    func goToStep(_ step: WizardStep) {
        currentStep = max(1, min(3, step))
    }

    func goNext() {
        if currentStep < 3 { currentStep += 1 }
    }

    func goBack() {
        if currentStep > 1 { currentStep -= 1 }
    }

    func reset() {
        name = ""
        let nextSize = initialPreferences.defaultBoardSize.rawValue
        size = nextSize
        timeframe = Self.resolveTimeframe(initialPreferences.defaultTimeframe)
        customStartDate = ""
        customEndDate = ""
        // Same coercion the initial factory uses, so reset can never
        // reintroduce an even-board+FREE mismatch.
        centerType = Self.coerceCenterType(
            size: nextSize,
            desired: Self.resolveCenterType(initialPreferences.defaultCenterType)
        )
        centerCustomName = initialPreferences.defaultCenterCustomName
        isRandomized = initialPreferences.defaultRandomize
        selectedTaskIds = []
        centerTaskId = nil
        currentStep = 1
    }

    // MARK: - Derived

    var tasksRequired: Int { tasksNeededForBoard(size: size, centerType: centerType) }
    var centerMode: Bool { centerType == .chosen }
    var isOddBoard: Bool { size % 2 != 0 }

    /// Computed timeframe boundaries (nil for `.custom`).
    var computedBoundaries: (start: Date, end: Date)? {
        computeTimeframeBoundaries(timeframe: timeframe, referenceDate: Date(), weekStartDay: weekStartDay)
    }

    /// Inline summary label for the chosen non-custom timeframe.
    var timeframeDisplayLabel: String? {
        guard let b = computedBoundaries else { return nil }
        return playgroundTimeframeLabel(timeframe: timeframe, startDate: b.start)
    }

    var isStep1Valid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if timeframe == .custom {
            guard !customStartDate.isEmpty && !customEndDate.isEmpty else { return false }
            guard customEndDate >= customStartDate else { return false }
        }
        return true
    }

    var step1ValidationMessage: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Board name is required." }
        if timeframe == .custom {
            if customStartDate.isEmpty || customEndDate.isEmpty {
                return "Pick a start and end date."
            }
            if customEndDate < customStartDate {
                return "End date must be on or after the start date."
            }
        }
        return nil
    }

    var isStep2Valid: Bool {
        guard selectedTaskIds.count >= tasksRequired else { return false }
        if centerMode {
            guard let id = centerTaskId, selectedTaskIds.contains(id) else { return false }
        }
        return true
    }

    var step2ValidationMessage: String? {
        let short = tasksRequired - selectedTaskIds.count
        if short > 0 {
            return "Pick \(short) more task\(short == 1 ? "" : "s")."
        }
        if centerMode {
            if centerTaskId == nil || !selectedTaskIds.contains(centerTaskId!) {
                return "Mark one selected task as the center."
            }
        }
        return nil
    }

    /// True when no meaningful edit has been made — the wizard can be
    /// dismissed without prompting. When a draft is being resumed this
    /// is always `false`: closing a resumed draft is always a decision
    /// worth confirming.
    var isPristine: Bool {
        if draftBoardId != nil { return false }
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if !selectedTaskIds.isEmpty { return false }
        if currentStep > 1 { return false }
        return true
    }
}
