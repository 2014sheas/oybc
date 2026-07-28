import SwiftUI

/// Gold arrival banner — the passive-completion "signature moment" (Shared
/// Counters P3). Shown on board-open when ≥1 shared-counter square filled in
/// from a log made elsewhere (Counter Detail / another board).
///
/// Copy contract (R3 board-play touchpoints — pinned byte-identical to web):
///   single:   "{taskTitle} filled in — you logged {counterName} elsewhere.
///              See every board ›"
///   multiple: "{K} squares filled in from your counters. Open counters ›"
///
/// `taskName` still names the SQUARE/task (e.g. "Do 200 push-ups"); only the
/// counter reference (`counterName`) switched to the pair-derived name — see
/// `BoardPlayViewModel.counterDisplayName`.
///
/// Riso gold surface with `Color.risoInkStatic` content — plain `risoInk`
/// flips to cream in dark mode and would vanish on the light gold fill
/// (reference_riso_adaptive_ink_fill_darkmode / reference_riso_dark_mode_tokens).
struct RisoArrivalBanner: View {

    /// Total arrived squares — selects the single-vs-multiple copy.
    let squareCount: Int
    /// The arrived square's task name (single-square variant only).
    let taskName: String?
    /// The arrived counter's display name (single-square variant only).
    let counterName: String?
    /// Tap the banner body → open Counter Detail (single counter) / the Hub.
    let onOpen: () -> Void
    /// ✕ dismiss.
    let onDismiss: () -> Void

    private var isSingle: Bool {
        squareCount == 1
            && !(taskName ?? "").isEmpty
            && !(counterName ?? "").isEmpty
    }

    private var bannerText: Text {
        if isSingle, let taskName = taskName, let counterName = counterName {
            return Text(taskName).italic().fontWeight(.bold)
                + Text(" filled in — you logged \(counterName) elsewhere. ")
                + Text("See every board ›").fontWeight(.bold)
        }
        return Text("\(squareCount) squares").fontWeight(.bold)
            + Text(" filled in from your counters. ")
            + Text("Open counters ›").fontWeight(.bold)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.risoInkStatic)

            Button(action: onOpen) {
                bannerText
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoInkStatic)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.risoInkStatic)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.risoGold)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInkStatic, lineWidth: Riso.Keyline.container)
        )
        .background(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .fill(Color.risoInkStatic)
                .offset(x: Riso.Shadow.small, y: Riso.Shadow.small)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Gold pulse applied to an arrived square's cell container (Shared Counters
/// P3). Attached at the `risoPlaySquare` call site — NOT inside
/// `RisoBoardPlayCell` — so the snapshot-covered cell internals are untouched
/// and the default board render is unchanged. Pulses a gold ring twice, then
/// settles.
struct ArrivePulseModifier: ViewModifier {
    /// When true, the square just arrived and should pulse.
    let active: Bool
    @State private var ringOpacity: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .strokeBorder(Color.risoGold, lineWidth: 3)
                    .opacity(ringOpacity)
                    .allowsHitTesting(false)
            )
            // The cell is already mounted when the arrival lands, so drive the
            // pulse off `active` flipping true — not `.onAppear`.
            .onChange(of: active) { _, isActive in
                if isActive { runPulse() }
            }
            .onAppear { if active { runPulse() } }
    }

    /// Two gold glows, then settle to invisible (matches the web `arriveGlow`
    /// keyframe's 2 iterations). A manual sequence rather than
    /// `repeatCount(_:autoreverses:)` so the final resting state is reliably 0
    /// (an even autoreversing repeat snaps back to the model value, leaving the
    /// ring stuck on).
    private func runPulse() {
        ringOpacity = 0
        let step: UInt64 = 450_000_000
        withAnimation(.easeInOut(duration: 0.45)) { ringOpacity = 0.9 }
        _Concurrency.Task { @MainActor in
            try? await _Concurrency.Task.sleep(nanoseconds: step)
            withAnimation(.easeInOut(duration: 0.45)) { ringOpacity = 0 }
            try? await _Concurrency.Task.sleep(nanoseconds: step)
            withAnimation(.easeInOut(duration: 0.45)) { ringOpacity = 0.9 }
            try? await _Concurrency.Task.sleep(nanoseconds: step)
            withAnimation(.easeInOut(duration: 0.45)) { ringOpacity = 0 }
        }
    }
}

extension View {
    /// Pulse this cell twice when it just arrived from an elsewhere log.
    func arrivePulse(active: Bool) -> some View {
        modifier(ArrivePulseModifier(active: active))
    }
}
