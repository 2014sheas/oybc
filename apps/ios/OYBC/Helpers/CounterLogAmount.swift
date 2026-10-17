import Foundation

/// One chip; `value == nil` is the custom `#` chip. Swift twin of `LogChip`
/// (`packages/shared/src/algorithms/logAmounts.ts`).
struct LogChip: Equatable {
    let value: CountValue?
    let label: String
}

/// The "+ Log" pill's action (docs/COUNTER_KINDS.md §5) — shared by the hub and Profile.
enum CounterPillAction: Equatable {
    case log(CountValue)
    case openDetail
}

/// Log-amount choices (docs/COUNTER_KINDS.md §5): chip sets per surface, the
/// pre-selected amount, the one-tap amount and the "+ Log" pill label.
/// Swift twin of `logAmounts.ts`, pinned by `logAmountVectors.json`.
///
/// `parseCustom` validates a raw custom-amount string at the kind (delegates
/// to `parseCountInput`); `nil` when it isn't a positive amount.
///
/// Shared (R3 board-play touchpoints) between `CounterDetailView`'s "#" chip
/// (R2) and the retired stepper sheet's "#" chip (R3) so the two amount-chip
/// UIs don't duplicate the rule. Swift twin of web's `parseCustomLogAmount`
/// (`apps/web/src/components/counters/amountChips.ts`) — keep both in sync
/// if the rule ever changes.
enum CounterLogAmount {
    static func parseCustom(_ raw: String, kind: CountKind = .discrete) -> CountValue? {
        parseCountInput(raw, kind: kind)
    }

    /// The fixed preset amounts backing both chip rows (excludes custom "#").
    static let presets: [CountValue] = [1, 10, 25]

    /// The chip to pre-select when a picker opens: the counter's remembered
    /// `defaultLogAmount` when it's a preset (so a habitual amount is one tap
    /// away), otherwise `1` — the fixed rows carry no dynamic chip for an
    /// off-preset default, and a non-preset initial value would leave nothing
    /// highlighted. `1` is the fallback because it matches the one-tap paths
    /// (plain cell tap, Hub "+ Log" pill), which log `defaultLogAmount ?? 1`;
    /// a fresh counter must not open on `+10` when everything else about it
    /// steps by one. Swift twin of web's `initialChipAmount`.
    static func initialChip(_ defaultLogAmount: CountValue?) -> CountValue {
        if let d = defaultLogAmount, presets.contains(d) { return d }
        return 1
    }

    private static let fixed: [CountKind: [CountValue]] = [
        .discrete: [1, 10, 25], .continuous: [0.5, 1, 5], .duration: [15, 30, 60],
    ]
    private static let customChip = LogChip(value: nil, label: "#")

    /// Hub / Counter Detail presets (no single goal there).
    static func fixedChipAmounts(_ kind: CountKind) -> [CountValue] { fixed[kind] ?? [] }

    /// ¼ · ½ · goal — stepped to the kind, floored at one step, de-duplicated;
    /// a goal <= 0 falls back to the fixed set.
    static func goalChipAmounts(goal: CountValue, kind: CountKind) -> [CountValue] {
        guard goal > 0 else { return fixedChipAmounts(kind) }
        let step = countTargetStep(kind)
        var values = [0.25, 0.5].map { max(step, roundToCountStep(goal * $0, kind: kind)) }
        values.append(goal)
        return values.enumerated().filter { values.firstIndex(of: $0.element) == $0.offset }.map(\.element)
    }

    /// The stepper sheet row. Discrete keeps `+1 · +10 · #`.
    static func boardSheetChips(kind: CountKind, goal: CountValue) -> [LogChip] {
        if kind == .discrete { return [LogChip(value: 1, label: "+1"), LogChip(value: 10, label: "+10"), customChip] }
        return goalChipAmounts(goal: goal, kind: kind).map { LogChip(value: $0, label: formatCount($0, kind: kind)) } + [customChip]
    }

    /// The Counter Detail Log card row.
    static func hubChips(kind: CountKind) -> [LogChip] {
        fixedChipAmounts(kind).map { LogChip(value: $0, label: formatCount($0, kind: kind)) } + [customChip]
    }

    /// One tap-to-log chip: a preset, the rest of the window's goal, or "Other…".
    /// Swift twin of `TapLogChip`.
    struct TapChip: Equatable {
        enum Role: String, Equatable { case preset, rest, other }
        /// `nil` on the "Other…" chip.
        let value: CountValue?
        let label: String
        let role: Role
    }

    /// Ceil to the kind's step, so the rest chip always reaches the goal.
    private static func ceilToCountStep(_ x: CountValue, kind: CountKind) -> CountValue {
        guard kind == .continuous else { return (x - 1e-9).rounded(.up) }
        return quantizeCount((quantizeCount(x * 10) - 1e-9).rounded(.up) / 10)
    }

    /// "5h30" / "45m" / "2h" — the duration rest chip's compact label.
    private static func compactDurationLabel(_ minutes: CountValue) -> String {
        let total = max(0, Int(minutes.rounded()))
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h" + String(format: "%02d", m)
    }

    /// The one-gesture chip row (docs/TASK_DETAIL_REDESIGN.md E3): the kind's
    /// fixed presets, then the rest of this window's goal (`+N ✓`, ceiled to
    /// the kind's step) when positive and not already a preset, then "Other…".
    /// No goal (Counter Detail) → no rest chip.
    ///
    /// - Parameters:
    ///   - kind: The counter's family kind.
    ///   - goal: The square's goal in this window, if any.
    ///   - windowedCount: The windowed count the rest is measured from.
    /// - Returns: The chips, ending in "Other…".
    static func tapChips(kind: CountKind, goal: CountValue?, windowedCount: CountValue = 0) -> [TapChip] {
        let presets = fixedChipAmounts(kind)
        var chips = presets.map { TapChip(value: $0, label: "+" + formatCount($0, kind: kind), role: .preset) }
        if let goal, goal > 0 {
            let rest = ceilToCountStep(goal - windowedCount, kind: kind)
            if rest.isFinite, rest > 0, !presets.contains(rest) {
                let text = kind == .duration ? compactDurationLabel(rest) : formatCount(rest, kind: kind)
                chips.append(TapChip(value: rest, label: "+\(text) ✓", role: .rest))
            }
        }
        chips.append(TapChip(value: nil, label: "Other…", role: .other))
        return chips
    }

    /// Closed-board late-log presets. Discrete keeps `+1 · +2 · +5`.
    static func lateLogChipAmounts(kind: CountKind, goal: CountValue) -> [CountValue] {
        kind == .discrete ? [1, 2, 5] : goalChipAmounts(goal: goal, kind: kind)
    }

    private static func presets(_ chips: [LogChip]) -> [CountValue] { chips.compactMap(\.value) }

    /// What a sheet opens on: a remembered default matching a chip selects it;
    /// Continuous / Duration show any other default on `#`; Discrete keeps
    /// `initialChip` (1 / 10 / 25, else 1); nothing remembered → first chip.
    static func initialSelection(
        kind: CountKind, chips: [LogChip], defaultLogAmount: CountValue?
    ) -> (amount: CountValue, isCustom: Bool) {
        let p = presets(chips)
        if let d = defaultLogAmount, p.contains(d) { return (d, false) }
        if kind == .discrete { return (initialChip(defaultLogAmount), false) }
        if let d = defaultLogAmount { return (d, true) }
        return (p.first ?? countTargetStep(kind), false)
    }

    /// The one-tap / long-press "+ Add {last}" amount.
    static func quickAmount(kind: CountKind, chips: [LogChip], defaultLogAmount: CountValue?) -> CountValue {
        if let d = defaultLogAmount { return d }
        return kind == .discrete ? 1 : (presets(chips).first ?? countTargetStep(kind))
    }

    /// The selected custom chip's label — "#3.1", "#1h 30m".
    static func customChipLabel(_ amount: CountValue, kind: CountKind) -> String {
        "#" + formatCount(amount, kind: kind)
    }

    /// "+ Log" / "+ Log 3.1" / "+ Log 30m".
    static func pillLabel(kind: CountKind, defaultLogAmount: CountValue?) -> String {
        guard kind != .discrete, let d = defaultLogAmount else { return "+ Log" }
        return "+ Log \(formatCount(d, kind: kind))"
    }

    /// A never-logged Continuous / Duration pill opens Counter Detail instead of logging.
    static func pillOpensDetail(kind: CountKind, defaultLogAmount: CountValue?) -> Bool {
        kind != .discrete && defaultLogAmount == nil
    }
}
