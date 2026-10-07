import SwiftUI

/// Pure helpers behind `GoalEntryView` (unit-tested without a view).
enum GoalEntryModel {
    /// Decimal pad only for Continuous.
    static func keyboard(for kind: CountKind) -> UIKeyboardType { kind == .continuous ? .decimalPad : .numberPad }

    /// Field text → wheel columns (0/0 when blank or invalid).
    static func wheelFields(_ text: String) -> (hours: Int, minutes: Int) {
        let total = Int(parseCountInput(text, kind: .duration, allowZero: true) ?? 0)
        return (total / 60, total % 60)
    }

    /// Wheel columns → field text; 0h 0m is "" (no entry), never a 0 goal.
    static func text(hours: Int, minutes: Int) -> String {
        let total = hours * 60 + minutes
        return total == 0 ? "" : formatCountForInput(CountValue(total), kind: .duration)
    }
}

/// The one amount-entry field (docs/COUNTER_KINDS.md §5). Discrete / Continuous
/// wrap `RisoNumberField` with the kind's keypad and an optional unit suffix;
/// Duration shows the value with a chevron and an inline h / min wheel
/// (1-minute steps — owner rule). `text` is in `parseCountInput` grammar.
/// Web twin: `GoalEntry.tsx`.
struct GoalEntryView: View {
    let kind: CountKind
    @Binding var text: String
    var placeholder: String? = nil
    var suffix: String? = nil
    var startsOpen: Bool = false

    @State private var wheelOpen = false

    var body: some View {
        if kind == .duration { durationBody } else { numericBody }
    }

    private var numericBody: some View {
        ZStack(alignment: .trailing) {
            RisoNumberField(placeholder: placeholder ?? "100", text: $text, keyboard: GoalEntryModel.keyboard(for: kind))
            if let suffix, !suffix.isEmpty {
                Text(suffix)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.trailing, 11)
                    .allowsHitTesting(false)
            }
        }
    }

    private var durationBody: some View {
        VStack(spacing: 8) {
            Button { wheelOpen.toggle() } label: {
                HStack {
                    Text(text.isEmpty ? (placeholder ?? "0h 0m") : formatCount(parseCountInput(text, kind: .duration, allowZero: true) ?? 0, kind: .duration))
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(text.isEmpty ? Color.risoMuted : Color.risoInk)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.risoMuted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, 11)
                .frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.risoPaper))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Duration, \(text.isEmpty ? "not set" : text)")
            if isOpen { wheel }
        }
    }

    private var isOpen: Bool { wheelOpen || startsOpen }

    private var wheel: some View {
        let fields = GoalEntryModel.wheelFields(text)
        return HStack(spacing: 0) {
            Picker("Hours", selection: Binding(
                get: { fields.hours },
                set: { text = GoalEntryModel.text(hours: $0, minutes: GoalEntryModel.wheelFields(text).minutes) }
            )) {
                ForEach(0...999, id: \.self) { Text("\($0) hours").tag($0) }
            }
            Picker("Minutes", selection: Binding(
                get: { fields.minutes },
                set: { text = GoalEntryModel.text(hours: GoalEntryModel.wheelFields(text).hours, minutes: $0) }
            )) {
                ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) }
            }
        }
        .pickerStyle(.wheel)
        .frame(height: 132)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.risoPaper2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.risoInk.opacity(0.35), lineWidth: 1.5))
    }
}
