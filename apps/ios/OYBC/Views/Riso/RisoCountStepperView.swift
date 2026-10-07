import SwiftUI

/// The wizard member row's compact target stepper (docs/BOARD_SOURCES.md
/// §Member rules; handoff "Counting member"), kind-aware
/// (docs/COUNTER_KINDS.md §5): steps 1 for Discrete, 0.1 for Continuous,
/// 1 minute for Duration. 32pt pill, 1.5pt ink border, radius 999,
/// 32pt − / typeable value / 32pt ＋. Moved out of `RisoSpecialTaskPanel.swift`
/// (was `RisoInlineStepperView(style: .compact)`).
/// Web twin: `CounterStepper` `size="compact"` + `kind`.
///
/// Typing is committed when the field loses focus, or folded into a −/＋ tap
/// (see ``RisoCountStepperMath``), and clamped to `min…max`. There is
/// deliberately no return-key commit: the number pads have no return key.
struct RisoCountStepperView: View {
    @Binding var value: CountValue
    let kind: CountKind
    /// Lower bound; defaults to one step of the kind.
    var min: CountValue? = nil
    let max: CountValue
    /// Static text inside the pill after the field — the member row's goal
    /// ("/ 30 miles"). Not editable. Web twin: the `suffix` prop.
    var suffix: String? = nil

    /// Uncommitted typing; nil while not editing, so an external value change
    /// (a Split-up recompute, an undo) shows through immediately.
    @State private var draft: String? = nil
    @FocusState private var isFieldFocused: Bool

    private var lower: CountValue { min ?? countTargetStep(kind) }

    var body: some View {
        HStack(spacing: 0) {
            stepButton("−", label: "Decrease target", disabled: effectiveValue <= lower) {
                step(by: -1)
            }
            TextField("", text: fieldText)
                .font(.risoBody(13, .extraBold))
                .foregroundStyle(Color.risoInk)
                .multilineTextAlignment(.center)
                .keyboardType(GoalEntryModel.keyboard(for: kind))
                .focused($isFieldFocused)
                // Width follows the goal's printed length so a wide goal
                // isn't clipped (web sizes the input the same way).
                .frame(width: CGFloat(Swift.max(2, formatCountForInput(max, kind: kind).count) + 1) * 8)
                .accessibilityLabel("Target")
                .onChange(of: isFieldFocused) { _, focused in
                    if focused {
                        draft = formatCountForInput(value, kind: kind)
                        // Select-all on focus: the field IS the first
                        // responder here, so a nil-target action reaches
                        // exactly it (never a sibling field).
                        DispatchQueue.main.async {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.selectAll(_:)),
                                to: nil, from: nil, for: nil
                            )
                        }
                    } else {
                        commitDraft()
                    }
                }
            if let suffix {
                Text(suffix)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 2)
                    // Hidden from VoiceOver: on its own it names nothing
                    // ("slash 30 miles" between "Target" and "Increase
                    // target"). The goal reaches VoiceOver via the counting
                    // title; identical on web (`CounterStepper.tsx`).
                    .accessibilityHidden(true)
            }
            stepButton("＋", label: "Increase target", disabled: effectiveValue >= max) {
                step(by: 1)
            }
        }
        .frame(height: 32)
        .background(Color.risoPaper2)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    /// The field's text: the uncommitted draft while editing, the live value otherwise.
    private var fieldText: Binding<String> {
        Binding(
            get: { draft ?? formatCountForInput(value, kind: kind) },
            set: { draft = $0 }
        )
    }

    /// The number the −/＋ buttons act on AND gate their disabled state by —
    /// the uncommitted draft when it parses, else the live value.
    private var effectiveValue: CountValue {
        RisoCountStepperMath.base(value: value, draft: draft, kind: kind, min: lower, max: max)
    }

    /// Parse, clamp to `min…max` and write back; an unparseable entry simply
    /// reverts (no error state — the stepper is never in a bad state).
    private func commitDraft() {
        guard let draft else { return }
        self.draft = nil
        guard let committed = RisoCountStepperMath.committed(draft: draft, kind: kind, min: lower, max: max)
        else { return }
        if committed != value { value = committed }
    }

    /// Step by one kind step from the COMMITTED value. A SwiftUI `Button` tap
    /// does not resign the field's first responder, so the commit is folded in
    /// here; web gets the same ordering for free (mousedown blurs the input).
    private func step(by delta: CountValue) {
        let next = RisoCountStepperMath.stepped(
            value: value, draft: draft, delta: delta, kind: kind, min: lower, max: max
        )
        draft = nil
        if next != value { value = next }
    }

    private func stepButton(
        _ glyph: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(glyph)
                // 15, not 12: at 32pt the smaller glyph read thin against the
                // 13pt value beside it. Web's `.compactButton` carries 15px.
                .font(.risoHead(15, .extraBold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// The compact stepper's pure arithmetic, lifted out of the SwiftUI view so
/// the ordering rule — **a −/＋ tap commits any uncommitted typing first** —
/// is unit-testable without mounting a view with `@State`/`@FocusState`.
/// Web twin: `counterStepperMath.ts` (`compactStepperBase` / `compactStepperNext`).
enum RisoCountStepperMath {

    /// The value an uncommitted draft resolves to at `kind`, clamped to
    /// `min…max`, or nil when it isn't a valid entry (the field then reverts).
    ///
    /// - Parameters:
    ///   - draft: The raw field text.
    ///   - kind: The counter's kind (the draft parses at it).
    ///   - min: Lower bound (inclusive).
    ///   - max: Upper bound (inclusive).
    /// - Returns: The clamped value, or nil when `draft` isn't valid.
    static func committed(draft: String, kind: CountKind, min: CountValue, max: CountValue) -> CountValue? {
        guard let parsed = parseCountInput(draft, kind: kind, allowZero: true) else { return nil }
        return Swift.min(max, Swift.max(min, parsed))
    }

    /// The number the −/＋ buttons operate on (and gate by): the uncommitted
    /// draft when it parses, else the live value.
    ///
    /// - Parameters:
    ///   - value: The committed value.
    ///   - draft: The uncommitted field text, or nil when not editing.
    ///   - kind: The counter's kind.
    ///   - min: Lower bound (inclusive).
    ///   - max: Upper bound (inclusive).
    /// - Returns: The effective value.
    static func base(value: CountValue, draft: String?, kind: CountKind, min: CountValue, max: CountValue) -> CountValue {
        guard let draft, let c = committed(draft: draft, kind: kind, min: min, max: max) else {
            return value
        }
        return c
    }

    /// The value a ±1 tap produces: one kind step (1, 0.1, or 1 minute) off
    /// ``base(value:draft:kind:min:max:)``, quantized and clamped.
    ///
    /// - Parameters:
    ///   - value: The committed value.
    ///   - draft: The uncommitted field text, or nil when not editing.
    ///   - delta: `-1` or `+1`.
    ///   - kind: The counter's kind.
    ///   - min: Lower bound (inclusive).
    ///   - max: Upper bound (inclusive).
    /// - Returns: The stepped value.
    static func stepped(
        value: CountValue, draft: String?, delta: CountValue, kind: CountKind, min: CountValue, max: CountValue
    ) -> CountValue {
        let from = base(value: value, draft: draft, kind: kind, min: min, max: max)
        return Swift.min(max, Swift.max(min, quantizeCount(from + delta * countTargetStep(kind))))
    }
}
