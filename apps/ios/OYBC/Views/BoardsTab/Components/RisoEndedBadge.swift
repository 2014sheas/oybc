import SwiftUI

/// **ENDED** pill (Board Edit redesign slice 4, D14) — a board whose window
/// closed but hasn't been closed/sealed yet ("Ended, not closed": still
/// logging until the user closes it, or it auto-closes at the next window's
/// end). Gold fill / ink-static text / 2px ink border, twin of
/// `RisoSealedBadge`'s CLOSED (paper-2 fill / ink).
struct RisoEndedBadge: View {
    var body: some View {
        Text("ENDED")
            .font(.risoHead(10, .bold))
            .tracking(0.6)
            .foregroundStyle(Color.risoInkStatic)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Capsule().fill(Color.risoGold))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
    }
}

#if DEBUG
#Preview("Ended Badge") {
    ZStack {
        RisoPaperBackground()
        RisoEndedBadge()
    }
}
#endif
