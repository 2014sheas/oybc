import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for the Account & security page (handoff §5c). Renders the
/// presentational leaf `AccountSecurityContent` (props + closures), so — unlike
/// the AuthService-bound container — it needs no Firebase. Covers the
/// provider-gated states (password-only, OAuth-only, all linked, single
/// provider) plus the delete-confirm and a status banner.
@MainActor
final class AccountSecuritySnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func state(password: Bool, google: Bool, apple: Bool) -> ProviderState {
        let count = [password, google, apple].filter { $0 }.count
        return ProviderState(hasPassword: password, hasGoogle: google, hasApple: apple, providerCount: count)
    }

    private func content(
        _ providerState: ProviderState,
        email: String = "alex@example.com",
        status: String? = nil,
        error: String? = nil,
        deleteConfirm: Bool = false
    ) -> some View {
        AccountSecurityContent(
            email: email,
            providerState: providerState,
            statusMessage: status,
            errorMessage: error,
            showDeleteConfirm: .constant(deleteConfirm)
        )
    }

    // MARK: - Provider-gated states

    /// Password user: Change email + Change password rows; Apple/Google both
    /// "Connect"; password is the only provider so no disconnect.
    func testPasswordOnlyLight() {
        assertSnapshot(
            of: content(state(password: true, google: false, apple: false)),
            as: .image(layout: .fixed(width: 393, height: 720)),
            record: recordMode
        )
    }

    func testPasswordOnlyDark() {
        assertSnapshot(
            of: content(state(password: true, google: false, apple: false)),
            as: .image(layout: .fixed(width: 393, height: 720), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    /// OAuth-only user (Google): "Add a password" replaces change email/password;
    /// Google connected (only provider → no disconnect); Apple "Connect".
    func testGoogleOnlyLight() {
        assertSnapshot(
            of: content(state(password: false, google: true, apple: false)),
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    /// All three linked: change email/password available; Apple + Google both
    /// connected with a Disconnect affordance (count > 1).
    func testAllLinkedLight() {
        assertSnapshot(
            of: content(state(password: true, google: true, apple: true)),
            as: .image(layout: .fixed(width: 393, height: 720)),
            record: recordMode
        )
    }

    /// Apple-only: single provider → Disconnect hidden; "Add a password" shown.
    func testAppleOnlyLight() {
        assertSnapshot(
            of: content(state(password: false, google: false, apple: true)),
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    // MARK: - Delete confirm + banners

    func testDeleteConfirmLight() {
        assertSnapshot(
            of: content(state(password: true, google: true, apple: false), deleteConfirm: true),
            as: .image(layout: .fixed(width: 393, height: 820)),
            record: recordMode
        )
    }

    func testStatusBannerLight() {
        assertSnapshot(
            of: content(state(password: true, google: false, apple: false),
                        status: "Verification link sent to new@example.com. Tap it there to finish the change."),
            as: .image(layout: .fixed(width: 393, height: 780)),
            record: recordMode
        )
    }
}
