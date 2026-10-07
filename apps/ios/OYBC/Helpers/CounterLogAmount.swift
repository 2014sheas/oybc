import Foundation

/// One chip; `value == nil` is the custom `#` chip. Swift twin of `LogChip`
/// (`packages/shared/src/algorithms/logAmounts.ts`).
struct LogChip: Equatable {
    let value: CountValue?
    let label: String
}

/// Log-amount choices (docs/COUNTER_KINDS.md §5): chip sets per surface, the
/// pre-selected amount, the one-tap amount and the "+ Log" pill label.
/// Swift twin of `logAmounts.ts`, pinned by `logAmountVectors.json`.
///
/// `parseCustom` validates a raw custom-amount string at the kind (delegates
/// to `parseCountInput`); `nil` when it isn't a positive amount.
///
/// Shared (R3 board-play touchpoints) between `CounterDetailView`'s "#" chip
/// (R2) and `RisoCountingStepperSheet`'s "#" chip (R3) so the two amount-chip
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
