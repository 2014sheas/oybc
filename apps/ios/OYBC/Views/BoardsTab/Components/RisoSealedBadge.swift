import SwiftUI

/// Sealed-board frozen-record pill (Windowed Completion §Effects of sealed +
/// §Open questions OQ1 resolution: no distinct "ended-but-empty" treatment —
/// a single functional badge regardless of greenlog outcome).
///
/// User-facing label is "CLOSED" — "sealed" is internal Windowed-Completion
/// vocabulary and never appears in UI copy (Closed / Close out family).
///
/// Shown in place of the live status badge on both `RisoBoardCard` (board
/// list) and `BoardPlayView`'s header — a sealed board's frozen grid +
/// existing progress/bingo meta already convey how much was completed.
///
/// Deliberately an OUTLINE look — `Color.risoPaper2` fill, `Color.risoInk`
/// text + a keyline — same neutral-provenance vocabulary as
/// `RisoRecurringBadge` (never a filled status color, since Sealed isn't a
/// `BoardStatus`). `Color.risoInk` is used here only as TEXT/BORDER, never as
/// a FILL behind cream content — see `docs/RISO_UI_CHECKLIST.md`.
struct RisoSealedBadge: View {
    var body: some View {
        Text("CLOSED")
            .font(.risoHead(10, .bold))
            .tracking(0.6)
            .foregroundStyle(Color.risoInk)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Capsule().fill(Color.risoPaper2))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
    }
}

#if DEBUG
#Preview("Sealed Badge") {
    ZStack {
        RisoPaperBackground()
        VStack(spacing: 14) {
            RisoSealedBadge()
            HStack(spacing: 8) {
                RisoSealedBadge()
                RisoRecurringBadge()
            }
        }
        .padding()
    }
}
#endif
