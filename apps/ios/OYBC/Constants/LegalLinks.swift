import Foundation

/// One in-app link to a hosted legal document.
struct LegalLink: Identifiable, Hashable {
    /// Row / link text shown in the app.
    let label: String
    /// Absolute https URL of the hosted page.
    let url: URL

    var id: String { label }
}

/// Legal documents — the iOS mirror of `packages/shared/src/constants/legalLinks.ts`
/// (the single cross-platform definition of where OYBC's Privacy Policy and Terms
/// of Use live). Keep the two in lock-step; `LegalLinksTests` reads the TS file
/// and fails on drift.
///
/// The pages are static files in `apps/coming-soon`, served on oybc.com by
/// Firebase Hosting. App Store Review requires the privacy policy inside the
/// app (Guideline 5.1.1(i)) and, once subscriptions ship, both links on the
/// paywall (3.1.2).
enum LegalLinks {
    /// The hosted Privacy Policy.
    static let privacyPolicy = LegalLink(
        label: "Privacy Policy",
        url: URL(string: "https://oybc.com/privacy")!
    )

    /// The hosted Terms of Use.
    static let termsOfUse = LegalLink(
        label: "Terms of Use",
        url: URL(string: "https://oybc.com/terms")!
    )

    /// Every legal link, in the order the app lists them.
    static let all: [LegalLink] = [privacyPolicy, termsOfUse]
}
