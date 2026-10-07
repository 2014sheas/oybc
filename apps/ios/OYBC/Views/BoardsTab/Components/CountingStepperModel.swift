import Foundation

/// The stepper sheet's chip / amount state (docs/COUNTER_KINDS.md §5). Web
/// twin: `countingLogModel.ts`. Pure — unit-tested without the sheet.
///
/// Discrete standalone: no chips, − / + step 1. Discrete shared: `+1 · +10 · #`
/// (the custom row + OK stays in the sheet). Continuous / Duration: ¼ · ½ ·
/// goal · # chips set the always-open amount field; − / + apply the field.
struct CountingStepperModel: Equatable {
    let kind: CountKind
    let chips: [LogChip]
    let isShared: Bool
    /// The amount field's text (`parseCountInput` grammar) — Continuous / Duration.
    var amountText: String
    /// The chosen chip / confirmed custom amount.
    var selectedAmount: CountValue
    /// The amount is an explicit custom entry — persisted as the default on log.
    var isCustom: Bool

    /// The state a sheet opens on.
    ///
    /// - Parameters:
    ///   - kind: The family kind.
    ///   - goal: The square's goal.
    ///   - defaultLogAmount: The remembered last-used amount.
    ///   - isShared: The square is in a shared-counter group.
    /// - Returns: The opening model.
    static func initial(kind: CountKind, goal: CountValue, defaultLogAmount: CountValue?, isShared: Bool) -> CountingStepperModel {
        let chips = CounterLogAmount.boardSheetChips(kind: kind, goal: goal)
        let sel = CounterLogAmount.initialSelection(kind: kind, chips: chips, defaultLogAmount: defaultLogAmount)
        return CountingStepperModel(kind: kind, chips: chips, isShared: isShared,
                                    amountText: formatCountForInput(sel.amount, kind: kind),
                                    selectedAmount: sel.amount, isCustom: sel.isCustom)
    }

    /// Chips show for every Continuous / Duration square and for shared Discrete squares.
    var showsChips: Bool { kind != .discrete || isShared }

    /// The amount − / + apply: the field for the new kinds, the chip for
    /// shared Discrete, 1 otherwise. `nil` when the field holds no valid amount.
    var amount: CountValue? {
        if kind != .discrete { return parseCountInput(amountText, kind: kind) }
        return isShared ? selectedAmount : 1
    }

    /// A chip tap: the chip's amount, not custom.
    mutating func selectChip(_ value: CountValue) {
        selectedAmount = value
        isCustom = false
        amountText = formatCountForInput(value, kind: kind)
    }

    /// `#` on a Continuous / Duration square: clears the field for a typed
    /// amount. Not custom until the user edits the field (nothing persists).
    mutating func beginCustomEntry() {
        amountText = ""
        isCustom = false
    }

    /// The chip to highlight: `#` for a custom amount; otherwise the chip
    /// matching the amount in effect (none while the field is blank / invalid).
    var selectedChipIndex: Int? {
        if isCustom { return chips.count - 1 }
        guard let current = kind == .discrete ? selectedAmount : amount else { return nil }
        return chips.firstIndex { $0.value == current }
    }

    /// A field edit: custom unless it parses to a chip's amount.
    mutating func setText(_ raw: String) {
        amountText = raw
        let parsed = parseCountInput(raw, kind: kind)
        isCustom = parsed.map { v in !chips.contains { $0.value == v } } ?? true
        if let parsed { selectedAmount = parsed }
    }

    /// "+ 3.1 mi" / "+ 2h 38m" / "+ 10"; "+" when the field is invalid.
    func addLabel(unit: String) -> String {
        guard let a = amount else { return "+" }
        return kind == .discrete ? "+ \(formatCount(a, kind: kind))" : "+ \(formatCountWithUnit(a, kind: kind, unit: unit))"
    }
}
