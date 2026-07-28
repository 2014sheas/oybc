import XCTest
@testable import OYBC

/// Tests for `UserPreferences.init(from:)` — the forward-compatible JSON
/// decoder added in Phase 0.
///
/// The decoder runs on every read of the `preferences` JSON column, so
/// it has to gracefully handle:
///   - Records written by an older client that didn't emit every key.
///   - Records written by a peer with a wrong-typed value.
///   - Completely empty objects.
///
/// In all of those cases the missing or invalid field should fall back
/// to `UserPreferences.defaults`, leaving any valid sibling fields
/// preserved. Without this behaviour, a single bad key from a
/// misbehaving peer would wipe the entire local preferences row.
final class UserPreferencesCodableTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Helpers

    private func decode(_ json: String) throws -> UserPreferences {
        guard let data = json.data(using: .utf8) else {
            XCTFail("Test fixture is not valid UTF-8")
            return .defaults
        }
        return try decoder.decode(UserPreferences.self, from: data)
    }

    // MARK: - Round-trip

    func testRoundTripPreservesEveryField() throws {
        let original = UserPreferences(
            weekStartDay: .sunday,
            defaultBoardSize: .four,
            defaultCenterType: .none,
            defaultTimeframe: .weekly,
            defaultRandomize: false,
            defaultCenterCustomName: "Wild Card",
            theme: .dark,
            recurringDailyEnabled: true,
            recurringWeeklyEnabled: false,
            recurringMonthlyEnabled: true,
            recurringYearlyEnabled: false
        )
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(UserPreferences.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - INDEFINITE default timeframe (web-settable, previously undecodable on iOS)

    func testIndefiniteDefaultTimeframeDecodesAndRoundTrips() throws {
        // Web's `mergeUserPreferences` accepts Timeframe.INDEFINITE as a valid
        // `defaultTimeframe` even though it isn't currently a picker option in
        // either platform's UI. Before this enum gained an `.indefinite` case,
        // this payload silently fell back to `.custom` on decode.
        let json = """
        {
          "weekStartDay": "monday",
          "defaultBoardSize": 5,
          "defaultCenterType": "free",
          "defaultTimeframe": "indefinite",
          "defaultRandomize": true,
          "defaultCenterCustomName": "",
          "theme": "system"
        }
        """
        let decoded = try decode(json)
        XCTAssertEqual(decoded.defaultTimeframe, .indefinite)

        let reencoded = try encoder.encode(decoded)
        let redecoded = try decoder.decode(UserPreferences.self, from: reencoded)
        XCTAssertEqual(redecoded.defaultTimeframe, .indefinite, "Must not degrade to .custom on re-encode.")
    }

    // MARK: - Missing keys

    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try decode("{}")
        XCTAssertEqual(decoded, .defaults)
    }

    func testMissingKeysFallBackPerField() throws {
        // Only weekStartDay and theme present; everything else missing.
        let json = """
        { "weekStartDay": "sunday", "theme": "dark" }
        """
        let decoded = try decode(json)
        XCTAssertEqual(decoded.weekStartDay, .sunday)
        XCTAssertEqual(decoded.theme, .dark)
        // Missing fields fall back to defaults rather than failing the whole decode.
        XCTAssertEqual(decoded.defaultBoardSize, UserPreferences.defaults.defaultBoardSize)
        XCTAssertEqual(decoded.defaultCenterType, UserPreferences.defaults.defaultCenterType)
        XCTAssertEqual(decoded.defaultTimeframe, UserPreferences.defaults.defaultTimeframe)
        XCTAssertEqual(decoded.defaultRandomize, UserPreferences.defaults.defaultRandomize)
        XCTAssertEqual(decoded.defaultCenterCustomName, UserPreferences.defaults.defaultCenterCustomName)
    }

    // MARK: - Malformed / wrong-typed values

    func testMalformedFieldsFallBackToDefaults() throws {
        // Every value is the wrong type. Each should individually fall
        // back without preventing the rest of the object from decoding.
        let json = """
        {
          "weekStartDay": 42,
          "defaultBoardSize": "four",
          "defaultCenterType": true,
          "defaultTimeframe": 999,
          "defaultRandomize": "yes",
          "defaultCenterCustomName": null,
          "theme": ["dark"]
        }
        """
        let decoded = try decode(json)
        XCTAssertEqual(decoded, .defaults, "Every malformed field should reset to its default.")
    }

    func testValidFieldsArePreservedWhenSiblingsAreMalformed() throws {
        // A real peer-poisoning scenario: the ones we recognise stay,
        // the garbage ones reset.
        let json = """
        {
          "weekStartDay": "sunday",
          "defaultBoardSize": "this is not a number",
          "theme": "light"
        }
        """
        let decoded = try decode(json)
        XCTAssertEqual(decoded.weekStartDay, .sunday)
        XCTAssertEqual(decoded.theme, .light)
        XCTAssertEqual(
            decoded.defaultBoardSize,
            UserPreferences.defaults.defaultBoardSize,
            "Malformed defaultBoardSize should fall back without affecting valid siblings."
        )
    }

    // MARK: - Phase 6.1 recurring fields (forward-compat for pre-6.1 peers)

    func testPre61PayloadDecodesRecurringFieldsAsTrue() throws {
        // A user doc written by a pre-6.1 client has all the legacy fields
        // but none of the recurring*Enabled keys. With the post-6.1d
        // defaults, missing keys auto-upgrade to true so the core boards
        // become discoverable on first open. Users who explicitly toggled
        // them off keep their explicit choice (covered below).
        let json = """
        {
          "weekStartDay": "monday",
          "defaultBoardSize": 5,
          "defaultCenterType": "free",
          "defaultTimeframe": "custom",
          "defaultRandomize": true,
          "defaultCenterCustomName": "",
          "theme": "system"
        }
        """
        let decoded = try decode(json)
        XCTAssertTrue(decoded.recurringDailyEnabled)
        XCTAssertTrue(decoded.recurringWeeklyEnabled)
        XCTAssertTrue(decoded.recurringMonthlyEnabled)
        XCTAssertTrue(decoded.recurringYearlyEnabled)
    }

    func testExplicitFalseValuesArePreservedAcrossDefault() throws {
        // Users who explicitly opted out of specific timeframes (toggled
        // off on the prefs page) keep their explicit `false` even though
        // the default is now `true`. Missing fields still upgrade to the
        // new default.
        let json = """
        {
          "weekStartDay": "monday",
          "defaultBoardSize": 5,
          "defaultCenterType": "free",
          "defaultTimeframe": "custom",
          "defaultRandomize": true,
          "defaultCenterCustomName": "",
          "theme": "system",
          "recurringDailyEnabled": false,
          "recurringMonthlyEnabled": false
        }
        """
        let decoded = try decode(json)
        XCTAssertFalse(decoded.recurringDailyEnabled)
        XCTAssertTrue(decoded.recurringWeeklyEnabled)   // missing → default true
        XCTAssertFalse(decoded.recurringMonthlyEnabled)
        XCTAssertTrue(decoded.recurringYearlyEnabled)   // missing → default true
    }

    func testMalformedRecurringFieldsFallBackToTrue() throws {
        let json = """
        {
          "weekStartDay": "monday",
          "defaultBoardSize": 5,
          "defaultCenterType": "free",
          "defaultTimeframe": "custom",
          "defaultRandomize": true,
          "defaultCenterCustomName": "",
          "theme": "system",
          "recurringDailyEnabled": "yes",
          "recurringWeeklyEnabled": 1,
          "recurringMonthlyEnabled": null,
          "recurringYearlyEnabled": "true"
        }
        """
        let decoded = try decode(json)
        XCTAssertTrue(decoded.recurringDailyEnabled)
        XCTAssertTrue(decoded.recurringWeeklyEnabled)
        XCTAssertTrue(decoded.recurringMonthlyEnabled)
        XCTAssertTrue(decoded.recurringYearlyEnabled)
    }
}
