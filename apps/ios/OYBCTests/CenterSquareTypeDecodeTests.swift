import XCTest
import GRDB
@testable import OYBC

/// Regression guard for the CUSTOM_FREE removal: a legacy `"custom_free"` value
/// (from an unmigrated peer's Firestore doc or an old local SQLite row) must
/// decode to `.free` rather than throwing/failing the fetch. Mirrors the web
/// Zod `preprocess` coercion so both platforms tolerate the retired value.
final class CenterSquareTypeDecodeTests: XCTestCase {

    func test_codable_coerces_legacy_custom_free_to_free() throws {
        let json = Data("\"custom_free\"".utf8)
        let decoded = try JSONDecoder().decode(CenterSquareType.self, from: json)
        XCTAssertEqual(decoded, .free)
    }

    func test_grdb_fromDatabaseValue_coerces_legacy_custom_free_to_free() throws {
        let decoded = try XCTUnwrap(CenterSquareType.fromDatabaseValue("custom_free".databaseValue))
        XCTAssertEqual(decoded, .free)
    }

    func test_known_values_still_decode() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(CenterSquareType.self, from: Data("\"chosen\"".utf8)),
            .chosen
        )
        XCTAssertEqual(
            try XCTUnwrap(CenterSquareType.fromDatabaseValue("free".databaseValue)),
            .free
        )
    }
}
