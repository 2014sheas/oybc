/**
 * Legal documents — the SINGLE cross-platform definition of where OYBC's
 * Privacy Policy and Terms of Use live and what the in-app links are called.
 * Mirrored in Swift by `apps/ios/OYBC/Constants/LegalLinks.swift`; keep the two
 * in lock-step (`LegalLinksTests.swift` reads this file and fails on drift).
 *
 * The pages are static files in `apps/coming-soon` (`privacy.html` /
 * `terms.html`), served at these clean URLs on oybc.com by Firebase Hosting
 * (`cleanUrls` in firebase.json). App Store Review requires the privacy policy
 * to be reachable inside the app (Guideline 5.1.1(i)) and, once subscriptions
 * ship, both links on the paywall (3.1.2).
 */

/** One in-app link to a hosted legal document. */
export interface LegalLink {
  /** Row / link text shown in the apps. */
  readonly label: string;
  /** Absolute https URL of the hosted page. */
  readonly url: string;
}

/** The hosted legal documents, in the order the apps list them. */
export const LEGAL_LINKS = {
  privacyPolicy: { label: 'Privacy Policy', url: 'https://oybc.com/privacy' },
  termsOfUse: { label: 'Terms of Use', url: 'https://oybc.com/terms' },
} as const satisfies Record<string, LegalLink>;
