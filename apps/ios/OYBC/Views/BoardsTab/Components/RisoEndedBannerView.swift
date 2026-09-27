import SwiftUI

/// The **Ended, not closed** banner (Board Edit redesign slice 4, D14):
/// shown above the grid when a board's window has ended but it hasn't been
/// closed yet — still logging until the user closes it or it auto-closes at
/// the next window's end. Red keyline card, replaces the old web-only
/// `expiredBanner` copy ("Board expired on…") on iOS with the new verbatim
/// text.
struct RisoEndedBannerView: View {
    /// Formatted end date, e.g. "Sep 30".
    let date: String

    var body: some View {
        Text("Board ended on \(date). Still logging until you close it.")
            .font(.risoBody(12, .semibold))
            .foregroundStyle(Color.risoRed)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.risoPaper2)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoRed, lineWidth: Riso.Keyline.container)
            )
    }
}

#if DEBUG
#Preview("Ended banner — light") {
    ZStack {
        RisoPaperBackground()
        RisoEndedBannerView(date: "Sep 30")
            .padding(Riso.gutter)
    }
}

#Preview("Ended banner — dark") {
    ZStack {
        RisoPaperBackground()
        RisoEndedBannerView(date: "Sep 30")
            .padding(Riso.gutter)
    }
    .environment(\.colorScheme, .dark)
}
#endif
