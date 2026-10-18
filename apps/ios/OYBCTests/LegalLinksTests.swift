import XCTest
@testable import OYBC

/// Pins `LegalLinks` (Swift) to `LEGAL_LINKS` in
/// `packages/shared/src/constants/legalLinks.ts`, the cross-platform source of
/// truth for the Privacy Policy / Terms of Use URLs and labels. Reads the TS
/// file straight from the checkout (via `#filePath`, the same source-relative
/// lookup the snapshot suite uses for its baselines) so a URL or label changed
/// on one platform only fails here instead of shipping a mismatched link.
final class LegalLinksTests: XCTestCase {

    /// Repo-relative path of the shared TypeScript definition.
    private static let sharedPath = "packages/shared/src/constants/legalLinks.ts"

    /// Loads the shared TS source from the checkout this test was built from.
    private func sharedSource(filePath: String = #filePath) throws -> String {
        let repoRoot = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent() // OYBCTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repo root
        let url = repoRoot.appendingPathComponent(Self.sharedPath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Extracts `{ label: '…', url: '…' }` for one `LEGAL_LINKS` key.
    private func sharedEntry(_ key: String, in source: String) throws -> (label: String, url: String) {
        let pattern = "\(key):\\s*\\{\\s*label:\\s*'([^']+)',\\s*url:\\s*'([^']+)'\\s*\\}"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        guard
            let match = regex.firstMatch(in: source, range: range),
            let labelRange = Range(match.range(at: 1), in: source),
            let urlRange = Range(match.range(at: 2), in: source)
        else {
            XCTFail("LEGAL_LINKS.\(key) not found in \(Self.sharedPath)")
            throw XCTSkip("shared entry missing")
        }
        return (String(source[labelRange]), String(source[urlRange]))
    }

    func testPrivacyPolicyMatchesSharedDefinition() throws {
        let shared = try sharedEntry("privacyPolicy", in: try sharedSource())
        XCTAssertEqual(LegalLinks.privacyPolicy.label, shared.label)
        XCTAssertEqual(LegalLinks.privacyPolicy.url.absoluteString, shared.url)
    }

    func testTermsOfUseMatchesSharedDefinition() throws {
        let shared = try sharedEntry("termsOfUse", in: try sharedSource())
        XCTAssertEqual(LegalLinks.termsOfUse.label, shared.label)
        XCTAssertEqual(LegalLinks.termsOfUse.url.absoluteString, shared.url)
    }

    func testAllListsPrivacyThenTerms() {
        XCTAssertEqual(LegalLinks.all, [LegalLinks.privacyPolicy, LegalLinks.termsOfUse])
    }
}
