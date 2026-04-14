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
            theme: .dark
        )
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(UserPreferences.self, from: encoded)
        XCTAssertEqual(decoded, original)
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
}
