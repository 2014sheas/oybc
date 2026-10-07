import SwiftUI

/// The one counter-kind picker (docs/COUNTER_KINDS.md §5): a three-segment
/// card `RisoSegmented` with the D4 lock states. Web twin: `KindPicker.tsx`.
///
/// When `onRequest` is set a tap on a live segment calls it instead of
/// writing `selection`, so the caller can confirm Continuous → Discrete
/// (`KindSwitchConfirmView`, Task 8) and write the binding itself.
struct KindPickerView: View {
    @Binding var selection: CountKind
    let lock: KindPickerLock
    var onRequest: ((CountKind) -> Void)? = nil

    var body: some View {
        RisoSegmented(
            options: CountKind.allCases.map { (value: $0, label: $0.label) },
            selection: Binding(
                get: { selection },
                set: { next in
                    guard next != selection else { return }
                    if let onRequest { onRequest(next) } else { selection = next }
                }
            ),
            lockedValues: Set(CountKind.allCases.filter { isKindSegmentLocked(lock, segment: $0) }),
            lockGlyphValues: Set(CountKind.allCases.filter { kindSegmentShowsLock(lock, segment: $0, selected: selection) })
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kind")
    }
}

/// A linked row's kind (D5): kind chip + shared dots, then
/// "{counter} · {all-time} all-time". Never a picker.
struct KindTagView: View {
    let kind: CountKind
    var counterName: String? = nil
    var lifetime: CountValue? = nil

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(kind.label).font(.risoHead(12, .bold))
                HStack(spacing: 2) {
                    Circle().frame(width: 5, height: 5)
                    Circle().frame(width: 5, height: 5)
                }
                .accessibilityHidden(true)
            }
            .foregroundStyle(Color.risoPaper)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoBlue))
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
            if let counterName, let lifetime {
                Text("\(counterName) · \(formatCountTotal(lifetime, kind: kind)) all-time")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 38, alignment: .leading)
    }
}
