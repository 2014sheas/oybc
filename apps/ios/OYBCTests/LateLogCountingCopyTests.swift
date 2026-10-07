import XCTest
@testable import OYBC

final class LateLogCountingCopyTests: XCTestCase {
    func testChipsAndReadoutPerKind() {
        XCTAssertEqual(LateLogCountingCopy.chips(kind: .continuous, goal: 26.2), [6.6, 13.1, 26.2])
        XCTAssertEqual(LateLogCountingCopy.chips(kind: .discrete, goal: 5), [1, 2, 5])
        XCTAssertEqual(LateLogCountingCopy.chipLabel(158, kind: .duration), "+2h 38m")
        XCTAssertEqual(LateLogCountingCopy.chipLabel(6.6, kind: .continuous), "+6.6")
        XCTAssertEqual(LateLogCountingCopy.readout(current: 21.3, max: 26.2, unit: "mi", kind: .continuous), "21.3/26.2 mi")
        XCTAssertEqual(LateLogCountingCopy.readout(current: 540, max: 630, unit: "", kind: .duration), "9h/10h 30m")
        XCTAssertEqual(LateLogCountingCopy.readout(current: 3, max: 5, unit: "mi", kind: .discrete), "3/5 mi")
    }
}
