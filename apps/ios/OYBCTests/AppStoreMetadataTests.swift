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

    /// The declared purposes and linkage the manifest must carry per collected
    /// data type. The first four are what the app sends off-device for its own
    /// functionality (Firebase Auth email / uid / display name + Firestore user
    /// content): linked to the user. The last two are Crashlytics' crash
    /// reporting (`CrashReporting`): never linked, because no user id or user
    /// content is ever attached to a report. Nothing is used for tracking.
    private static let expectedCollectedData: [String: (linked: Bool, purposes: Set<String>)] = [
        "NSPrivacyCollectedDataTypeEmailAddress": (true, ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]),
        "NSPrivacyCollectedDataTypeName": (true, ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]),
        "NSPrivacyCollectedDataTypeUserID": (true, ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]),
        "NSPrivacyCollectedDataTypeOtherUserContent": (true, ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]),
        "NSPrivacyCollectedDataTypeCrashData": (false, ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]),
        "NSPrivacyCollectedDataTypeOtherDiagnosticData": (false, ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]),
    ]

    /// Exactly the expected data types, each declared once, with the expected
    /// linkage and purposes, and none used for tracking.
    func testPrivacyManifestCollectedDataTypes() throws {
        let manifest = try loadManifest()
        let collected = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertEqual(Set(types), Set(Self.expectedCollectedData.keys))
        XCTAssertEqual(types.count, Set(types).count, "a data type is declared twice")
        for entry in collected {
            let type = try XCTUnwrap(entry["NSPrivacyCollectedDataType"] as? String)
            let expected = try XCTUnwrap(Self.expectedCollectedData[type], type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, expected.linked, type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, type)
            let purposes = try XCTUnwrap(entry["NSPrivacyCollectedDataTypePurposes"] as? [String], type)
            XCTAssertEqual(Set(purposes), expected.purposes, type)
            XCTAssertEqual(purposes.count, Set(purposes).count, "\(type) repeats a purpose")
        }
    }

    // MARK: - Crash reporting

    /// Crash data is declared NOT linked to the user — which is only true while
    /// the app attaches no identity to reports. The shipping sources must never
    /// call `Crashlytics.setUserID` (nor attach user content as custom keys / logs).
    func testSourcesNeverIdentifyTheUserToCrashlytics() throws {
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OYBCTests
            .deletingLastPathComponent()  // apps/ios
            .appendingPathComponent("OYBC")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        let identityCalls = ["setUserID", "setCustomValue", "setCustomKeysAndValues", ".log(", ".record("]
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("import FirebaseCrashlytics") else { continue }
            offenders += identityCalls.filter { text.contains($0) }.map { "\(url.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(offenders, [], "Crashlytics must carry no user identity — update the privacy manifest first")
    }

    /// Developer builds and the hosted test suites must never send reports;
    /// shipping builds must. This suite runs in Debug.
    func testCrashCollectionIsDisabledInDebugOnly() {
        #if DEBUG
        XCTAssertFalse(CrashReporting.isCollectionEnabled)
        #else
        XCTAssertTrue(CrashReporting.isCollectionEnabled)
        #endif
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
