import XCTest
@testable import OYBC

final class CountingMenuLabelsTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(CountingMenuLabels.add(amount: 3.1, kind: .continuous, unit: "mi", action: "Run"), "+ Add 3.1 mi")
        XCTAssertEqual(CountingMenuLabels.remove(amount: 90, kind: .duration, unit: "", action: "Practice"), "− Remove 1h 30m")
        XCTAssertEqual(CountingMenuLabels.add(amount: 1, kind: .discrete, unit: "reps", action: "Do"), "+ Add 1 Do", "discrete keeps today's iOS string")
        XCTAssertEqual(CountingMenuLabels.remove(amount: 10, kind: .discrete, unit: "reps", action: "Do"), "− Remove 10 Do")
    }
}
