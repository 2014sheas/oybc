import XCTest
@testable import OYBC

final class ShuffleTests: XCTestCase {

    /// Empty array returns empty array
    func testEmptyArray() {
        let result = Shuffle.fisherYatesShuffle([Int]())
        XCTAssertEqual(result, [])
    }

    /// Single-element array returns unchanged
    func testSingleElement() {
        let result = Shuffle.fisherYatesShuffle([42])
        XCTAssertEqual(result, [42])
    }

    /// Result has the same length as input
    func testSameLength() {
        let input = [1, 2, 3, 4, 5]
        let result = Shuffle.fisherYatesShuffle(input)
        XCTAssertEqual(result.count, input.count)
    }

    /// Result contains all original elements (no duplicates, no missing)
    func testContainsAllElements() {
        let input = ["a", "b", "c", "d", "e"]
        let result = Shuffle.fisherYatesShuffle(input)
        XCTAssertEqual(result.sorted(), input.sorted())
    }

    /// Original array is not mutated
    func testDoesNotMutateOriginal() {
        let input = [1, 2, 3, 4, 5]
        let copy = input
        _ = Shuffle.fisherYatesShuffle(input)
        XCTAssertEqual(input, copy)
    }

    /// Works with strings (task names)
    func testStrings() {
        let input = ["Task 1", "Task 2", "Task 3"]
        let result = Shuffle.fisherYatesShuffle(input)
        XCTAssertEqual(result.sorted(), input.sorted())
    }

    /// Two-element array works correctly
    func testTwoElements() {
        let input = [1, 2]
        let result = Shuffle.fisherYatesShuffle(input)
        XCTAssertEqual(result.sorted(), [1, 2])
    }

    /// Large array (25 elements for 5x5 board) works correctly
    func testLargeArray() {
        let input = (1...25).map { "Task \($0)" }
        let result = Shuffle.fisherYatesShuffle(input)
        XCTAssertEqual(result.count, 25)
        XCTAssertEqual(result.sorted(), input.sorted())
    }

    /// Produces different orderings across multiple runs
    func testProducesDifferentOrderings() {
        let input = [1, 2, 3, 4, 5]
        var results = Set<String>()

        for _ in 0..<100 {
            let shuffled = Shuffle.fisherYatesShuffle(input)
            results.insert(shuffled.map(String.init).joined(separator: ","))
        }

        // With 100 shuffles of 5 elements (120 permutations),
        // we should see at least 2 distinct orderings
        XCTAssertGreaterThan(results.count, 1)
    }

    /// Distribution is roughly uniform (statistical test)
    func testUniformDistribution() {
        let n = 5
        let trials = 10000
        var counts = [Int: Int]()
        for v in 0..<n { counts[v] = 0 }

        for _ in 0..<trials {
            let result = Shuffle.fisherYatesShuffle([0, 1, 2, 3, 4])
            counts[result[0]]! += 1
        }

        let expected = Double(trials) / Double(n) // 2000
        for v in 0..<n {
            let count = Double(counts[v]!)
            // Allow 30% deviation from expected (generous for randomness)
            XCTAssertGreaterThan(count, expected * 0.7)
            XCTAssertLessThan(count, expected * 1.3)
        }
    }
}
