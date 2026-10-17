import SwiftUI

/// The one-gesture log row (docs/TASK_DETAIL_REDESIGN.md E3): presets and the
/// rest-of-goal chip are gold with an `inkStatic` keyline and a 2pt hard
/// shadow; "Other…" is a paper2 chip. A tap writes immediately — the caller
/// shows an `UndoStrip` instead of asking for confirmation. Web twin:
/// `components/riso/TapLogChipRow.tsx`.
///
/// Disabled (a write in flight) keeps the layout: opacity 0.45 and the shadow
/// collapses to 0 — chips are never hidden.
struct TapLogChipRow: View {

    /// Row scale — the square sheet's hero chips vs a compound child's inline row.
    enum Size {
        case regular
        case compact

        var height: CGFloat { self == .regular ? 44 : 34 }
        var keyline: CGFloat { self == .regular ? Riso.Keyline.container : Riso.Keyline.dense }
    }

    let chips: [CounterLogAmount.TapChip]
    var size: Size = .regular
    var disabled: Bool = false
    let onChip: (CounterLogAmount.TapChip) -> Void

    private static let gap: CGFloat = 6

    /// A chip's flex weight: "Other…" 1.1, a rest label of 4+ characters 1.3, else 1.
    static func weight(_ chip: CounterLogAmount.TapChip) -> CGFloat {
        switch chip.role {
        case .other: return 1.1
        case .rest: return chip.label.count >= 4 ? 1.3 : 1
        case .preset: return 1
        }
    }

    /// Point size: a long rest label shrinks to 13; the compact row is a size down.
    static func fontSize(_ chip: CounterLogAmount.TapChip, size: Size) -> CGFloat {
        switch chip.role {
        case .other: return size == .regular ? 14 : 12
        case .rest where chip.label.count >= 4: return 13
        default: return size == .regular ? 15 : 13
        }
    }

    var body: some View {
        GeometryReader { geo in
            let total = chips.reduce(0) { $0 + Self.weight($1) }
            let room = geo.size.width - Self.gap * CGFloat(max(chips.count - 1, 0))
            HStack(spacing: Self.gap) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    chipButton(chip)
                        .frame(width: total > 0 ? room * Self.weight(chip) / total : 0)
                }
            }
        }
        .frame(height: size.height)
        // The hard shadow draws outside the row's frame.
        .padding(.trailing, Riso.Shadow.small)
        .padding(.bottom, Riso.Shadow.small)
    }

    private func chipButton(_ chip: CounterLogAmount.TapChip) -> some View {
        let isOther = chip.role == .other
        return Button { onChip(chip) } label: {
            Text(chip.label)
                .font(isOther ? .risoHead(Self.fontSize(chip, size: size), .bold) : .risoHead(Self.fontSize(chip, size: size), .extraBold))
                .monospacedDigit()
                .foregroundStyle(isOther ? Color.risoInk : Color.risoInkStatic)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: size.height, maxHeight: size.height)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(isOther ? Color.risoPaper2 : Color.risoGold))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(isOther ? Color.risoInk : Color.risoInkStatic, lineWidth: size.keyline)
                )
                .contentShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        }
        .buttonStyle(TapLogChipButtonStyle(collapsed: disabled))
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(isOther ? "Log another amount" : "Log \(chip.label)")
    }
}

/// Press = translate 2pt and the 2pt hard shadow to 0; `collapsed` (disabled)
/// draws no shadow at all.
private struct TapLogChipButtonStyle: ButtonStyle {
    let collapsed: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let offset = Riso.Shadow.small
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .fill(Color.risoInk)
                    .offset(x: pressed || collapsed ? 0 : offset, y: pressed || collapsed ? 0 : offset)
            )
            .offset(x: pressed ? offset : 0, y: pressed ? offset : 0)
            .animation(.easeOut(duration: Riso.pressDuration), value: pressed)
    }
}

#if DEBUG
#Preview("Tap-to-log chips") {
    VStack(spacing: 16) {
        TapLogChipRow(chips: CounterLogAmount.tapChips(kind: .discrete, goal: 20, windowedCount: 12), onChip: { _ in })
        TapLogChipRow(chips: CounterLogAmount.tapChips(kind: .duration, goal: 630, windowedCount: 270), size: .compact, onChip: { _ in })
        TapLogChipRow(chips: CounterLogAmount.tapChips(kind: .discrete, goal: 20, windowedCount: 12), disabled: true, onChip: { _ in })
    }
    .padding(Riso.gutter)
    .background(Color.risoPaper)
}
#endif
