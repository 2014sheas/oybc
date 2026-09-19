import XCTest
@testable import OYBC

/// Vector pins for ``SeededRng`` — the repo's one production LCG.
///
/// Byte-identical to the TypeScript suites
/// (`packages/shared/tests/algorithms/seededRng.test.ts` and
/// `packages/bingo-core/tests/seededRng.test.ts`): same seeds, same five
/// samples. That lockstep is what proves the Swift port of
/// `state = (state * 1664525 + 1013904223) mod 2^32`, sample = `state / 2^32`
/// cannot drift from the shared one — a wizard Preview seeded from a given
/// nonce previews the same targets on both platforms.
final class SeededRngTests: XCTestCase {

    /// Seed → its first five samples, copied verbatim from the shared suite.
    private let vectors: [UInt32: [Double]] = [
        0: [
            0.23606797284446657, 0.278566908556968, 0.8195337599609047, 0.6678668977692723,
            0.3840773708652705,
        ],
        1: [
            0.23645552527159452, 0.3692706737201661, 0.5042420323006809, 0.7048832636792213,
            0.05054362863302231,
        ],
        42: [
            0.2523451747838408, 0.08812504541128874, 0.5772811982315034, 0.22255426598712802,
            0.37566019711084664,
        ],
        4294967295: [
            0.2356804204173386, 0.18786314339376986, 0.13482548762112856, 0.6308505318593234,
            0.7176111130975187,
        ],
    ]

    func test_reproducesThePinnedSequenceForEverySeed() {
        for (seed, expected) in vectors {
            var rng = SeededRng(seed: seed)
            let actual = (0..<5).map { _ in rng.next() }
            XCTAssertEqual(actual, expected, "seed \(seed) drifted from the shared vector")
        }
    }

    func test_yieldsSamplesInUnitIntervalAndReproducesPerSeed() {
        var a = SeededRng(seed: 12345)
        var b = SeededRng(seed: 12345)
        for _ in 0..<200 {
            let sample = a.next()
            XCTAssertGreaterThanOrEqual(sample, 0)
            XCTAssertLessThan(sample, 1)
            XCTAssertEqual(sample, b.next())
        }
    }

    func test_differentSeedsDivergeWithinTheFirstFewSamples() {
        var a = SeededRng(seed: 7)
        var b = SeededRng(seed: 8)
        let left = (0..<5).map { _ in a.next() }
        let right = (0..<5).map { _ in b.next() }
        XCTAssertNotEqual(left, right, "adjacent seeds must not produce identical sequences")
    }
}
