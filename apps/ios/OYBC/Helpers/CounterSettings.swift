import Foundation

// MARK: - Shared counter settings (docs/SHARED_COUNTER_SETTINGS.md §1)
//
// Swift twin of `packages/shared/src/algorithms/counterSettings.ts`: a counter
// ROOT's editable name, `#N` singular / plural title templates, and default
// goal per core timeframe. Every field is optional and ABSENT means "the
// default" (D3 — never backfilled, never written on read), so an untouched
// counter renders byte-for-byte as before. Pinned by
// `counterSettingsVectors.json` (`CounterSettingsVectorTests`). A change here
// is a change in two places.

/// Default goals per core timeframe, in the counter's kind units (minutes for
/// Duration). Stored on `Task.timeframeGoals` as a JSON string (GRDB v42);
/// nil members are omitted from the JSON, matching the TS optional keys.
struct CounterTimeframeGoals: Codable, Equatable {
    var daily: CountValue?
    var weekly: CountValue?
    var monthly: CountValue?
    var yearly: CountValue?

    /// The goal for one core timeframe.
    subscript(_ t: CounterSettings.GoalTimeframe) -> CountValue? {
        get {
            switch t {
            case .daily: daily
            case .weekly: weekly
            case .monthly: monthly
            case .yearly: yearly
            }
        }
        set {
            switch t {
            case .daily: daily = newValue
            case .weekly: weekly = newValue
            case .monthly: monthly = newValue
            case .yearly: yearly = newValue
            }
        }
    }

    /// True when no timeframe carries a goal.
    var isEmpty: Bool { daily == nil && weekly == nil && monthly == nil && yearly == nil }
}

enum CounterSettings {

    /// The placeholder a title template carries for the count.
    static let countPlaceholder = "#N"

    /// The core timeframes a counter may carry a default goal for, shortest first.
    enum GoalTimeframe: String, CaseIterable {
        case daily, weekly, monthly, yearly

        /// The matching board timeframe.
        var timeframe: Timeframe {
            switch self {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
        }
    }

    /// The root fields these helpers read (a stored `Task` maps via `init(task:)`).
    struct Fields: Equatable {
        var title: String?
        var action: String?
        var unit: String?
        var maxCount: CountValue?
        var countKind: CountKind?
        var counterName: String?
        var titleTemplateSingular: String?
        var titleTemplatePlural: String?
        var timeframeGoals: CounterTimeframeGoals?

        init(
            title: String? = nil, action: String? = nil, unit: String? = nil, maxCount: CountValue? = nil,
            countKind: CountKind? = nil, counterName: String? = nil, titleTemplateSingular: String? = nil,
            titleTemplatePlural: String? = nil, timeframeGoals: CounterTimeframeGoals? = nil
        ) {
            self.title = title
            self.action = action
            self.unit = unit
            self.maxCount = maxCount
            self.countKind = countKind
            self.counterName = counterName
            self.titleTemplateSingular = titleTemplateSingular
            self.titleTemplatePlural = titleTemplatePlural
            self.timeframeGoals = timeframeGoals
        }

        init(task: Task) {
            self.init(
                title: task.title, action: task.action, unit: task.unit, maxCount: task.maxCount,
                countKind: task.countKind, counterName: task.counterName,
                titleTemplateSingular: task.titleTemplateSingular, titleTemplatePlural: task.titleTemplatePlural,
                timeframeGoals: task.timeframeGoals
            )
        }
    }

    /// The root settings that decide a rendered title (name + templates). Twin
    /// of the TS `CounterTitleSettings`.
    struct TitleSettings: Equatable {
        var counterName: String?
        var titleTemplateSingular: String?
        var titleTemplatePlural: String?

        init(counterName: String? = nil, titleTemplateSingular: String? = nil, titleTemplatePlural: String? = nil) {
            self.counterName = counterName
            self.titleTemplateSingular = titleTemplateSingular
            self.titleTemplatePlural = titleTemplatePlural
        }

        init(task: Task) {
            self.init(
                counterName: task.counterName, titleTemplateSingular: task.titleTemplateSingular,
                titleTemplatePlural: task.titleTemplatePlural
            )
        }
    }

    /// The four settings as stored on a root (nil = default). The counter
    /// sheet's edit carries the full post-edit value.
    struct Stored: Equatable {
        var counterName: String?
        var titleTemplateSingular: String?
        var titleTemplatePlural: String?
        var timeframeGoals: CounterTimeframeGoals?
    }

    /// A singular / plural template pair.
    struct Templates: Equatable {
        let singular: String
        let plural: String
    }

    // MARK: - Titles

    /// A stored string field, trimmed, or nil when absent / blank.
    static func storedText(_ value: String?) -> String? {
        let t = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func trimmed(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The count as a title renders it — locale-independent (titles are stored
    /// data): `Xh Ym` for Duration, else the 2dp-trimmed number. Exactly the
    /// legacy generator's rendering.
    static func formatTitleCount(_ goal: CountValue, kind: CountKind) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        return kind == .duration
            ? formatCount(goal, kind: .duration, locale: posix)
            : formatCount(goal, kind: .continuous, locale: posix)
    }

    /// The default templates (spec §1b): `"{action} #N {unit}"` (Duration
    /// `"{action} #N"`); the singular defaults to the plural (D2).
    static func defaultTitleTemplates(_ root: Fields) -> Templates {
        let action = trimmed(root.action)
        let plural = root.countKind == .duration
            ? "\(action) \(countPlaceholder)"
            : "\(action) \(countPlaceholder) \(trimmed(root.unit))"
        return Templates(singular: plural, plural: plural)
    }

    /// The templates in effect: a stored plural, else the default; a stored
    /// singular, else the effective plural (D2).
    static func effectiveTitleTemplates(_ root: Fields) -> Templates {
        let plural = storedText(root.titleTemplatePlural) ?? defaultTitleTemplates(root).plural
        return Templates(singular: storedText(root.titleTemplateSingular) ?? plural, plural: plural)
    }

    /// The name without a title fallback: `counterName`, else
    /// `formatCounterName(action, unit)` (may be "").
    private static func nameFromFields(_ root: Fields) -> String {
        storedText(root.counterName) ?? CounterName.formatCounterName(action: root.action, unit: root.unit)
    }

    /// The label the hub, Counter Detail, pickers and quick-add show (§1a):
    /// `counterName`, else `formatCounterName(action, unit)`, else the stored title.
    static func counterDisplayName(_ root: Fields) -> String {
        let name = nameFromFields(root)
        return name.isEmpty ? trimmed(root.title) : name
    }

    /// `counterDisplayName` for a stored task.
    static func counterDisplayName(_ task: Task) -> String {
        counterDisplayName(Fields(task: task))
    }

    /// Render a counter's title for `goal` (§1b): `goal == 1` → the singular
    /// template, else the plural; `#N` → `formatTitleCount`; a template
    /// without `#N` renders as-is; goal-less → the name. With no stored
    /// template the legacy formula renders unchanged (not even trimmed).
    static func renderCounterTitle(_ root: Fields, goal: CountValue?) -> String {
        guard let goal else { return nameFromFields(root) }
        let kind = root.countKind ?? .discrete
        let plural = storedText(root.titleTemplatePlural)
        let template = goal == 1 ? (storedText(root.titleTemplateSingular) ?? plural) : plural
        let count = formatTitleCount(goal, kind: kind)
        guard let template else {
            let action = trimmed(root.action)
            return kind == .duration ? "\(action) \(count)" : "\(action) \(count) \(trimmed(root.unit))"
        }
        return template.components(separatedBy: countPlaceholder).joined(separator: count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Default goals

    /// A stored goal when it is a usable positive number, else nil.
    private static func storedGoal(_ goals: CounterTimeframeGoals?, _ t: GoalTimeframe) -> CountValue? {
        guard let v = goals?[t], v.isFinite, v > 0 else { return nil }
        return v
    }

    /// The goal D4 derives for `target` from the nearest SET timeframe (tie →
    /// the shorter), scaled by `nominalWindowDays` and rounded up with
    /// `ceilToCountStep` (the member-rule auto-scaler's ratio + rounding).
    private static func derivedGoal(_ root: Fields, _ target: GoalTimeframe) -> CountValue? {
        guard storedGoal(root.timeframeGoals, target) == nil else { return nil }
        let all = GoalTimeframe.allCases
        let ti = all.firstIndex(of: target)!
        var best: (t: GoalTimeframe, d: Int)?
        for (i, t) in all.enumerated() where storedGoal(root.timeframeGoals, t) != nil {
            let d = abs(i - ti)
            if best == nil || d < best!.d { best = (t, d) }
        }
        guard let best, let source = storedGoal(root.timeframeGoals, best.t),
              let sourceDays = BoardSources.nominalWindowDays(best.t.timeframe),
              let targetDays = BoardSources.nominalWindowDays(target.timeframe)
        else { return nil }
        return ceilToCountStep(source * CountValue(targetDays) / CountValue(sourceDays), kind: root.countKind ?? .discrete)
    }

    /// The derived (dimmed) default for every UNSET core timeframe (D4).
    static func derivedTimeframeGoals(_ root: Fields) -> [GoalTimeframe: CountValue?] {
        Dictionary(uniqueKeysWithValues: GoalTimeframe.allCases.map { ($0, derivedGoal(root, $0)) })
    }

    /// The default goal a counter brings to a board of `timeframe` (§1c): the
    /// stored default → one derived from the set defaults (D4) → the root's
    /// own goal → nil. CUSTOM / INDEFINITE boards never match (nil).
    static func resolveCounterDefaultGoal(_ root: Fields, timeframe: Timeframe) -> CountValue? {
        guard let t = GoalTimeframe(rawValue: timeframe.rawValue) else { return nil }
        if let goal = storedGoal(root.timeframeGoals, t) ?? derivedGoal(root, t) { return goal }
        guard let own = root.maxCount, own > 0 else { return nil }
        return own
    }
}
