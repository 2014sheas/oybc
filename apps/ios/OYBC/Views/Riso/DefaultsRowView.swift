import SwiftUI

/// Pure helpers behind `DefaultsRowView` (unit-tested without a view).
enum DefaultsRowModel {

    /// The text a Defaults cell shows: what was entered, else the derived
    /// default formatted for the field (dimmed), else empty.
    ///
    /// - Parameters:
    ///   - entered: The typed text for the cell.
    ///   - derived: The derived default for the cell, if any.
    ///   - kind: The counter's kind.
    /// - Returns: The cell's text and whether it is a dimmed derived default.
    static func cell(entered: String?, derived: CountValue?, kind: CountKind) -> (text: String, dim: Bool) {
        if let entered, !entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (entered, false) }
        if let derived { return (formatCountForInput(derived, kind: kind), true) }
        return ("", true)
    }

    /// The goals a set of typed cell texts resolves to (positive, parseable).
    ///
    /// - Parameters:
    ///   - texts: Typed text per timeframe.
    ///   - kind: The counter's kind.
    /// - Returns: The entered goals.
    static func goals(from texts: [CounterSettings.GoalTimeframe: String], kind: CountKind) -> [CounterSettings.GoalTimeframe: CountValue] {
        var out: [CounterSettings.GoalTimeframe: CountValue] = [:]
        for (t, text) in texts {
            if let v = parseCountInput(text, kind: kind), v > 0 { out[t] = v }
        }
        return out
    }

    /// Timeframes whose non-blank text does not parse as a positive goal.
    ///
    /// - Parameters:
    ///   - texts: Typed text per timeframe.
    ///   - kind: The counter's kind.
    /// - Returns: The invalid timeframes.
    static func invalid(_ texts: [CounterSettings.GoalTimeframe: String], kind: CountKind) -> Set<CounterSettings.GoalTimeframe> {
        Set(texts.compactMap { t, text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (parseCountInput(trimmed, kind: kind).map { $0 > 0 } ?? false) ? nil : t
        })
    }

    /// Seeds the typed texts from stored goals.
    static func texts(from goals: [CounterSettings.GoalTimeframe: CountValue], kind: CountKind) -> [CounterSettings.GoalTimeframe: String] {
        goals.mapValues { formatCountForInput($0, kind: kind) }
    }
}

/// The counter sheet's "Defaults" row: a default goal per core timeframe
/// (Daily / Weekly / Monthly / Yearly) in a 2x2 grid of kind-aware entries.
/// A cell the user set is solid; one derived from the others (D4) shows its
/// value dimmed on a hairline keyline; with nothing set anywhere every cell
/// is empty. Web twin: `DefaultsRow.tsx`.
struct DefaultsRowView: View {
    let kind: CountKind
    /// The counter's noun, shown as the numeric entries' suffix.
    let unit: String
    /// Typed text per timeframe ("" / absent = unset).
    @Binding var texts: [CounterSettings.GoalTimeframe: String]
    /// The derived default per timeframe (`CounterSettings.defaults(...).goals`).
    let derived: [CounterSettings.GoalTimeframe: CountValue?]

    private static let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let invalid = DefaultsRowModel.invalid(texts, kind: kind)
        VStack(alignment: .leading, spacing: 5) {
            Text("Defaults")
                .font(.risoHead(11, .bold))
                .tracking(0.3)
                .foregroundStyle(Color.risoMuted)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                ForEach(CounterSettings.GoalTimeframe.allCases, id: \.self) { t in
                    cell(t, invalid: invalid.contains(t))
                }
            }
        }
    }

    private func cell(_ t: CounterSettings.GoalTimeframe, invalid: Bool) -> some View {
        let shown = DefaultsRowModel.cell(entered: texts[t], derived: derived[t] ?? nil, kind: kind)
        return VStack(alignment: .leading, spacing: 4) {
            Text(t.timeframe.risoDisplayName.uppercased())
                .font(.risoHead(10, .bold))
                .tracking(0.6)
                .foregroundStyle(Color.risoMuted)
            GoalEntryView(
                kind: kind,
                text: Binding(
                    get: { shown.text },
                    set: { texts[t] = $0 }
                ),
                placeholder: "",
                suffix: unit.trimmingCharacters(in: .whitespacesAndNewlines),
                invalid: invalid,
                dimmed: shown.dim
            )
            .accessibilityLabel("\(t.timeframe.risoDisplayName) default")
        }
    }
}
