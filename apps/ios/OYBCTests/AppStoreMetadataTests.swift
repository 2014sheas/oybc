import XCTest
@testable import OYBC

/// App Review blockers (ROADMAP Track L1): guards on what ships inside the
/// app bundle — the privacy manifest, the version strings and the
/// iPhone-only / portrait-only declaration. The tests run hosted in the app,
/// so the bundle under test is the built `OYBC.app`.
final class AppStoreMetadataTests: XCTestCase {

    /// The built app bundle (the test host).
    private var appBundle: Bundle { Bundle(for: AuthService.self) }

    /// Loads `PrivacyInfo.xcprivacy` from the app bundle as a dictionary.
    ///
    /// - Returns: The parsed manifest.
    /// - Throws: If the manifest is missing from the bundle or is not a plist dictionary.
    private func loadManifest() throws -> [String: Any] {
        let url = try XCTUnwrap(
            appBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy is not in the app bundle"
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    // MARK: - Privacy manifest

    /// OYBC does not track: no tracking flag, no tracking domains.
    func testPrivacyManifestDeclaresNoTracking() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
    }

    /// The only required-reason API the app's own sources call is
    /// `UserDefaults` (device-local flags and stores), reason `CA92.1`.
    func testPrivacyManifestDeclaresOnlyUserDefaultsWithOwnAppReason() throws {
        let manifest = try loadManifest()
        let apis = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(apis.count, 1)
        XCTAssertEqual(apis[0]["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryUserDefaults")
        XCTAssertEqual(apis[0]["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    }

    /// Exactly the data the app sends off-device for its own functionality
    /// (Firebase Auth email / uid / display name + Firestore user content),
    /// each linked to the user, never used for tracking.
    func testPrivacyManifestCollectedDataTypes() throws {
        let manifest = try loadManifest()
        let collected = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertEqual(Set(types), [
            "NSPrivacyCollectedDataTypeEmailAddress",
            "NSPrivacyCollectedDataTypeName",
            "NSPrivacyCollectedDataTypeUserID",
            "NSPrivacyCollectedDataTypeOtherUserContent",
        ])
        XCTAssertEqual(types.count, Set(types).count, "a data type is declared twice")
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(
                entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
            )
        }
    }

    // MARK: - Version strings

    /// `Info.plist` reads `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`;
    /// an unresolved reference expands to an empty or `$(`-prefixed string.
    func testVersionStringsAreResolvedBuildSettings() throws {
        let info = try XCTUnwrap(appBundle.infoDictionary)
        let marketing = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertNotNil(marketing.range(of: #"^\d+(\.\d+){1,2}$"#, options: .regularExpression), marketing)
        XCTAssertNotNil(build.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression), build)
    }

    // MARK: - Device family + orientation

    /// iPhone-only (no iPad layout exists) and portrait-only.
    func testBundleIsIPhoneOnlyAndPortraitOnly() throws {
        let info = try XCTUnwrap(appBundle.infoDictionary)
        XCTAssertEqual(info["UIDeviceFamily"] as? [Int], [1])
        XCTAssertEqual(info["UISupportedInterfaceOrientations"] as? [String], ["UIInterfaceOrientationPortrait"])
        XCTAssertNil(info["UISupportedInterfaceOrientations~ipad"])
    }
}
