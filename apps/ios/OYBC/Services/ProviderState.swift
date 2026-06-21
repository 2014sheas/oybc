import Foundation

/// Which sign-in providers are linked to the current account.
///
/// Derived from `Auth.auth().currentUser?.providerData` (provider IDs
/// `"password"`, `"google.com"`, `"apple.com"`). A pure value type with no
/// Firebase import so views — and snapshot tests — can build/consume it freely.
///
/// Drives the Account & security UI:
/// - Change email / Change password require `hasPassword` (OAuth-only accounts
///   instead see an "Add a password" affordance).
/// - A provider's unlink action is disabled when `providerCount == 1` (a user
///   must always keep at least one way to sign in).
struct ProviderState: Equatable {
    var hasPassword: Bool
    var hasGoogle: Bool
    var hasApple: Bool
    /// Number of distinct linked providers.
    var providerCount: Int

    static let none = ProviderState(hasPassword: false, hasGoogle: false, hasApple: false, providerCount: 0)

    /// True when removing a provider would leave the user with no way to sign in.
    var isLastProvider: Bool { providerCount <= 1 }

    // Firebase provider-ID constants.
    static let passwordProviderID = "password"
    static let googleProviderID = "google.com"
    static let appleProviderID = "apple.com"
}
