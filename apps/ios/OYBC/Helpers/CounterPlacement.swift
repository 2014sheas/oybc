import Foundation

// MARK: - Placing a shared counter on a board (docs/SHARED_COUNTER_SETTINGS.md §2)
//
// Swift twin of `packages/shared/src/algorithms/counterPlacement.ts`: which
// goal a per-board copy gets, whether a hand-added ROOT needs a copy at all,
// and the search-match set the wizard quick-add / library sheet / Board Edit
// picker share. Pinned by `counterPlacementVectors.json`
// (`CounterPlacementVectorTests`). Inert for a counter with no
// `timeframeGoals` but a goal of its own — every helper then answers exactly
// what placement did before; a counter with no goal at all resolves the kind
// fallback (`CounterSettings.fallbackDailyGoal`). A board's dates matter for
// CUSTOM only. A change here is a change in two places.
enum CounterPlacement {

    /// A usable positive goal, or nil.
    private static func positive(_ v: CountValue?) -> CountValue? {
        guard let v, v.isFinite, v > 0 else { return nil }
        return v
    }

    /// The root's default for a board window WITHOUT the root-goal fallback
    /// (`CounterSettings.windowDefaultGoal`: stored → D4-derived → the kind
    /// fallback for a counter with no goal at all; INDEFINITE as yearly;
    /// CUSTOM scaled to its dates). The member-rule auto-scaler consults this
    /// before its own pro-rating. TS twin: `counterTimeframeDefault`.
    ///
    /// - Parameters:
    ///   - root: The counter root's fields.
    ///   - timeframe: The board's timeframe.
    ///   - startDate: The board's start (CUSTOM only).
    ///   - endDate: The board's end (CUSTOM only).
    ///   - kindFallback: False for a caller with a goal of its own to pro-rate.
    /// - Returns: The timeframe default, or nil.
    static func counterTimeframeDefault(
        _ root: CounterSettings.Fields, timeframe: Timeframe, startDate: String? = nil, endDate: String? = nil,
        kindFallback: Bool = true
    ) -> CountValue? {
        CounterSettings.windowDefaultGoal(
            root, timeframe: timeframe, startDate: startDate, endDate: endDate, kindFallback: kindFallback
        )
    }

    /// ``counterTimeframeDefault(_:timeframe:startDate:endDate:kindFallback:)``
    /// for a member-rule window.
    static func counterTimeframeDefault(
        _ root: CounterSettings.Fields, window: BoardSources.BoardWindow, kindFallback: Bool = true
    ) -> CountValue? {
        counterTimeframeDefault(
            root, timeframe: window.timeframe, startDate: window.startDate, endDate: window.endDate,
            kindFallback: kindFallback
        )
    }

    /// The goal a per-board copy carries when it is placed on a board of
    /// `timeframe`: an EXISTING copy keeps its own goal; else
    /// `resolveCounterDefaultGoal` (stored → derived / kind fallback → the
    /// root's goal); else nil (a CUSTOM board whose dates don't parse, for a
    /// counter with no goal at all). TS twin: `placementGoalForCounter`.
    ///
    /// - Parameters:
    ///   - root: The counter root's fields.
    ///   - timeframe: The board's timeframe.
    ///   - startDate: The board's start (CUSTOM only).
    ///   - endDate: The board's end (CUSTOM only).
    ///   - existingCopyGoal: The goal of the row already holding the copy's id, if any.
    /// - Returns: The copy's goal, or nil.
    static func placementGoalForCounter(
        _ root: CounterSettings.Fields, timeframe: Timeframe, startDate: String? = nil, endDate: String? = nil,
        existingCopyGoal: CountValue? = nil
    ) -> CountValue? {
        positive(existingCopyGoal)
            ?? CounterSettings.resolveCounterDefaultGoal(root, timeframe: timeframe, startDate: startDate, endDate: endDate)
            ?? positive(root.maxCount)
    }

    /// A host's window for `counterPickGoal(_:window:)`.
    struct PickWindow: Equatable {
        let timeframe: Timeframe
        var startDate: String? = nil
        var endDate: String? = nil
    }

    /// `counterPickGoal` over a `PickWindow` (nil = Indefinite).
    static func counterPickGoal(_ root: CounterSettings.Fields, window: PickWindow?) -> CountValue? {
        counterPickGoal(root, timeframe: window?.timeframe, startDate: window?.startDate, endDate: window?.endDate)
    }

    /// The goal a NEW sub-task linked to a picked counter starts with (owner
    /// rule 2026-10-13: pre-filled, editable): the counter's default for the
    /// host's window, as a placement there resolves it. No window — or one
    /// that resolves nothing (a CUSTOM window whose dates don't parse) — reads
    /// as Indefinite, the yearly default, so a counter always yields a goal.
    /// TS twin: `counterPickGoal`.
    ///
    /// - Parameters:
    ///   - root: The picked counter's fields.
    ///   - timeframe: The host board's (or the compound's own) timeframe, if any.
    ///   - startDate: Its start (CUSTOM only).
    ///   - endDate: Its end (CUSTOM only).
    /// - Returns: The goal, or nil.
    static func counterPickGoal(
        _ root: CounterSettings.Fields, timeframe: Timeframe?, startDate: String? = nil, endDate: String? = nil
    ) -> CountValue? {
        let inWindow = timeframe.flatMap {
            placementGoalForCounter(root, timeframe: $0, startDate: startDate, endDate: endDate)
        }
        return inWindow ?? placementGoalForCounter(root, timeframe: .indefinite)
    }

    /// Whether hand-adding the ROOT itself must mint a per-board copy: only
    /// when it carries a timeframe default for this board that differs from
    /// its own goal. TS twin: `placementNeedsCopy`.
    ///
    /// - Parameters:
    ///   - root: The counter root's fields.
    ///   - timeframe: The board's timeframe.
    ///   - startDate: The board's start (CUSTOM only).
    ///   - endDate: The board's end (CUSTOM only).
    /// - Returns: True when a copy must be minted.
    static func placementNeedsCopy(
        _ root: CounterSettings.Fields, timeframe: Timeframe, startDate: String? = nil, endDate: String? = nil
    ) -> Bool {
        guard let dflt = counterTimeframeDefault(root, timeframe: timeframe, startDate: startDate, endDate: endDate)
        else { return false }
        return dflt != positive(root.maxCount)
    }

    /// Search normaliser: diacritics folded (canonical decomposition, combining
    /// marks U+0300–U+036F dropped), lowercased, whitespace runs collapsed,
    /// trimmed. TS twin: `normalizeSearchText`.
    ///
    /// - Parameter s: Any text.
    /// - Returns: The normalised text.
    static func normalizeSearchText(_ s: String?) -> String {
        let decomposed = (s ?? "").decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !(0x0300...0x036F).contains($0.value) }
        return String(String.UnicodeScalarView(decomposed)).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The normalised texts a counter is found by: name, noun, verb, the
    /// effective plural template with `#N` removed, and the stored title.
    private static func counterSearchTexts(_ root: CounterSettings.Fields) -> [String] {
        let plural = CounterSettings.effectiveTitleTemplates(root).plural
            .components(separatedBy: CounterSettings.countPlaceholder).joined(separator: " ")
        return [CounterSettings.counterDisplayName(root), root.unit, root.action, plural, root.title]
            .map(normalizeSearchText).filter { !$0.isEmpty }
    }

    /// Does `query` find this counter? Name, noun, verb and rendered plural
    /// title, case- and diacritic-insensitively, as a substring (every prefix
    /// and word match). An empty query matches. TS twin: `counterSearchMatches`.
    ///
    /// - Parameters:
    ///   - query: The typed search.
    ///   - root: The counter's fields.
    /// - Returns: True on a match.
    static func counterSearchMatches(_ query: String, root: CounterSettings.Fields) -> Bool {
        let q = normalizeSearchText(query)
        if q.isEmpty { return true }
        return counterSearchTexts(root).contains { $0.contains(q) }
    }

    /// The library / quick-add / picker task match: the title for every task,
    /// plus ``counterSearchMatches(_:root:)`` for a COUNTING task. TS twin:
    /// `taskSearchMatches`.
    ///
    /// - Parameters:
    ///   - query: The typed search.
    ///   - type: The task's type.
    ///   - fields: The task's title + counter fields.
    /// - Returns: True on a match.
    static func taskSearchMatches(_ query: String, type: TaskType, fields: CounterSettings.Fields) -> Bool {
        let q = normalizeSearchText(query)
        if q.isEmpty { return true }
        if normalizeSearchText(fields.title).contains(q) { return true }
        return type == .counting && counterSearchMatches(q, root: fields)
    }

    /// ``taskSearchMatches(_:type:fields:)`` for a stored task.
    static func taskSearchMatches(_ query: String, task: Task) -> Bool {
        taskSearchMatches(query, type: task.type, fields: CounterSettings.Fields(task: task))
    }

    /// Where a placed counter's goal comes from (nil = the quick-add / picker
    /// row asks for a Goal): the goal and whether it is a timeframe default (shown with
    /// the timeframe prefix) rather than the root's own goal.
    struct PlacementGoalSource: Equatable {
        let goal: CountValue
        let fromTimeframe: Bool
    }

    /// The goal a freshly placed copy would get on a board of `timeframe`,
    /// plus whether it is a timeframe default. Nil when nothing resolves (a
    /// CUSTOM board without parseable dates, for a counter with no goal at
    /// all — the row then offers a Goal entry). TS twin: `placementGoalSource`.
    ///
    /// - Parameters:
    ///   - root: The counter root's fields.
    ///   - timeframe: The board's timeframe.
    ///   - startDate: The board's start (CUSTOM only).
    ///   - endDate: The board's end (CUSTOM only).
    /// - Returns: The source, or nil.
    static func placementGoalSource(
        _ root: CounterSettings.Fields, timeframe: Timeframe, startDate: String? = nil, endDate: String? = nil
    ) -> PlacementGoalSource? {
        guard let goal = placementGoalForCounter(root, timeframe: timeframe, startDate: startDate, endDate: endDate)
        else { return nil }
        let dflt = counterTimeframeDefault(root, timeframe: timeframe, startDate: startDate, endDate: endDate)
        return PlacementGoalSource(goal: goal, fromTimeframe: dflt != nil)
    }
}
