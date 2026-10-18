import SwiftUI

/// The hosted legal documents as one quiet line of links —
/// "Privacy Policy · Terms of Use" — for the bottom of the sign-in screens
/// (`LoginView` under `AuthGateView`, and onboarding's sign-in step). Each
/// opens its page in the browser via SwiftUI `Link`.
///
/// Web twin: `apps/web/src/components/legal/LegalLinksFooter.tsx`.
struct LegalLinksFooter: View {
    /// The links to show; defaults to every hosted legal document.
    var links: [LegalLink] = LegalLinks.all

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                if index > 0 {
                    Text("·")
                        .accessibilityHidden(true)
                }
                Link(link.label, destination: link.url)
                    .underline()
            }
        }
        .font(.risoBody(12, .semibold))
        .foregroundStyle(Color.risoMuted)
        .tint(Color.risoMuted)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview {
    ZStack {
        RisoPaperBackground()
        LegalLinksFooter()
    }
}
#endif
