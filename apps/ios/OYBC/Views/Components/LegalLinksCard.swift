import SwiftUI

/// A Riso card listing the hosted legal documents (`LegalLinks.all`) as
/// tappable rows — "Privacy Policy", "Terms of Use" — each opening its page
/// in the browser via SwiftUI `Link`. Shown on Settings and Help.
///
/// Web twin: `apps/web/src/components/legal/LegalLinksCard.tsx`.
struct LegalLinksCard: View {
    /// The links to list; defaults to every hosted legal document.
    var links: [LegalLink] = LegalLinks.all

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                if index > 0 { rowDivider }
                Link(destination: link.url) {
                    RisoProfileRow(
                        icon: Self.icon(for: link),
                        label: link.label,
                        external: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    /// SF Symbol for a legal document's row.
    ///
    /// - Parameter link: The document.
    /// - Returns: `hand.raised` for the Privacy Policy, `doc.text` otherwise.
    static func icon(for link: LegalLink) -> String {
        link == LegalLinks.privacyPolicy ? "hand.raised" : "doc.text"
    }

    private var rowDivider: some View {
        Divider()
            .background(Color.risoInk.opacity(0.12))
            .padding(.horizontal, Riso.cardPadding)
    }
}

#if DEBUG
#Preview {
    ZStack {
        RisoPaperBackground()
        LegalLinksCard()
            .padding(Riso.gutter)
    }
}
#endif
