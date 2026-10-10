import SwiftUI

/// Pure helpers behind `TemplateFieldView` (unit-tested without a view).
enum TemplateFieldModel {

    /// Max length of a title template (twin of the web field's `maxLength`); the counter name takes 100.
    static let maxLength = 200

    /// The example count a title template renders at: singular 1; plural 12,
    /// Continuous 2.5, Duration 90 minutes ("1h 30m").
    ///
    /// - Parameters:
    ///   - plural: True for the plural field.
    ///   - kind: The counter's kind.
    /// - Returns: The example count.
    static func exampleCount(plural: Bool, kind: CountKind) -> CountValue {
        guard plural else { return 1 }
        switch kind {
        case .discrete: return 12
        case .continuous: return 2.5
        case .duration: return 90
        }
    }

    /// The `→ …` line: the effective template (typed, else the derived
    /// default) with `#N` replaced by the example count; a template without
    /// `#N` renders as-is; empty when there is nothing to show.
    ///
    /// - Parameters:
    ///   - typed: The typed (stored) template; blank = unset.
    ///   - derived: The default shown while unset.
    ///   - count: The example count.
    ///   - kind: The counter's kind.
    /// - Returns: The rendered example ("" = no row).
    static func rendered(typed: String, derived: String, count: CountValue, kind: CountKind) -> String {
        let trimmedTyped = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmedTyped.isEmpty ? derived.trimmingCharacters(in: .whitespacesAndNewlines) : trimmedTyped
        guard !effective.isEmpty else { return "" }
        return effective.components(separatedBy: CounterSettings.countPlaceholder)
            .joined(separator: CounterSettings.formatTitleCount(count, kind: kind))
    }
}

/// A counter sheet's optional text field under the shared counter settings'
/// "blank = unset" rule: while `text` is blank the field shows `derived` as
/// real DIMMED text on a hairline keyline; typing makes it solid and stores
/// it, clearing returns it to dimmed. A `→ {rendered}` row below previews the
/// effective template at an example count. The `#N` placeholder is plain
/// text. Web twin: `TemplateField.tsx`.
struct TemplateFieldView: View {
    let label: String
    /// The typed (stored) template; "" = unset.
    @Binding var text: String
    /// The default shown dimmed while `text` is blank.
    let derived: String
    /// The count the preview row renders `#N` at.
    let count: CountValue
    let kind: CountKind
    var placeholder: String = ""
    /// Show the `→ {rendered}` row (false for the Name field).
    var showsExample: Bool = true
    /// Longest accepted text (templates 200, the counter name 100).
    var maxLength: Int = TemplateFieldModel.maxLength

    private var isDim: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var shown: Binding<String> {
        Binding(
            get: { isDim ? derived : text },
            set: { text = String($0.prefix(maxLength)) }
        )
    }

    var body: some View {
        let rendered = TemplateFieldModel.rendered(typed: text, derived: derived, count: count, kind: kind)
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.risoHead(11, .bold))
                .tracking(0.3)
                .foregroundStyle(Color.risoMuted)
            RisoTextField(placeholder: placeholder, text: shown, dimmed: isDim)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
            if showsExample, !rendered.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("→")
                        .font(.risoHead(11, .extraBold))
                        .foregroundStyle(Color.risoMuted)
                        .accessibilityHidden(true)
                    Text(rendered)
                        .font(.risoHead(13, .bold))
                        .tracking(-0.13)
                        .foregroundStyle(isDim ? Color.risoMuted : Color.risoInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}
