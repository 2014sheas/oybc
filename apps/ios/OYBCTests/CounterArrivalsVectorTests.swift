import XCTest
@testable import OYBC

/// Cross-platform counter-arrivals match enforcement (SHARED_COUNTERS P3
/// PR A / issue #303).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/counterArrivalsVectors.json`)
/// through iOS's `detectCounterArrivals` in `Helpers/CounterArrivals.swift`.
/// The SAME fixture is exercised on the shared/web side by
/// `packages/shared/tests/algorithms/counterArrivals.test.ts` against
/// `@oybc/shared`'s `counterArrivals.ts`. Both suites passing against the
/// same vectors is what proves the two hand-mirrored implementations agree,
/// not just an audit claim.
///
/// `snapshotCounterSquares` isn't part of the fixture (different input/output
/// shape than the lastSeen+squares match); its 2 behavioral cases — including
/// a round-trip spanning both functions — are hand-written below, mirroring
/// the kept (not converted) TS tests.
final class CounterArrivalsVectorTests: XCTestCase {

    private struct VectorSquare: Decodable {
        let taskId: String
        let counterId: String
        let counterName: String
        let displayed: Int
    }

    private struct ExpectedCounter: Decodable, Equatable {
        let counterId: String
        let counterName: String
        let squareCount: Int
    }

    private struct ExpectedResult: Decodable {
        let arrivedTaskIds: [String]
        let arrivedCounters: [ExpectedCounter]
        let totalArrivedSquares: Int
    }

    private struct Vector: Decodable {
        let name: String
        let lastSeen: [String: Int]
        let squares: [VectorSquare]
        let expected: ExpectedResult
    }

    private struct Fixture: Decodable {
        let vectors: [Vector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CounterArrivalsVectorTests.self).url(
            forResource: "counterArrivalsVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "counterArrivalsVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func toSquare(_ s: VectorSquare) -> ArrivalSquare {
        ArrivalSquare(taskId: s.taskId, counterId: s.counterId, counterName: s.counterName, displayed: s.displayed)
    }

    func testDetectCounterArrivalsVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.vectors.isEmpty)
        for v in fixture.vectors {
            let squares = v.squares.map(toSquare)
            let result = detectCounterArrivals(lastSeen: v.lastSeen, squares: squares)
            XCTAssertEqual(result.arrivedTaskIds, v.expected.arrivedTaskIds, "Vector '\(v.name)' arrivedTaskIds")
            XCTAssertEqual(result.totalArrivedSquares, v.expected.totalArrivedSquares, "Vector '\(v.name)' totalArrivedSquares")
            XCTAssertEqual(result.arrivedCounters.count, v.expected.arrivedCounters.count, "Vector '\(v.name)' arrivedCounters count")
            for (actual, expected) in zip(result.arrivedCounters, v.expected.arrivedCounters) {
                XCTAssertEqual(actual.counterId, expected.counterId, "Vector '\(v.name)' counterId")
                XCTAssertEqual(actual.counterName, expected.counterName, "Vector '\(v.name)' counterName")
                XCTAssertEqual(actual.squareCount, expected.squareCount, "Vector '\(v.name)' squareCount")
            }
        }
    }

    // MARK: - snapshotCounterSquares (hand-written; kept, not fixture-converted)

    func testSnapshotCounterSquaresBuildsMapFromCurrentSquares() {
        let squares = [
            ArrivalSquare(taskId: "t1", counterId: "c1", counterName: "Push-ups", displayed: 20),
            ArrivalSquare(taskId: "t2", counterId: "c1", counterName: "Push-ups", displayed: 5),
        ]
        let snap = snapshotCounterSquares(squares: squares)
        XCTAssertEqual(snap, ["t1": 20, "t2": 5])
    }

    func testSnapshotCounterSquaresRoundTripYieldsNoArrivalsOnNextDetect() {
        let squares = [
            ArrivalSquare(taskId: "t1", counterId: "c1", counterName: "Push-ups", displayed: 20),
            ArrivalSquare(taskId: "t2", counterId: "c1", counterName: "Push-ups", displayed: 8),
        ]
        let snap = snapshotCounterSquares(squares: squares)
        let result = detectCounterArrivals(lastSeen: snap, squares: squares)
        XCTAssertEqual(result.totalArrivedSquares, 0)
    }
}
