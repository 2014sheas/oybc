import XCTest
@testable import OYBC

/// Board Edit slice 3 (D10) — invariants of `Shuffle.shuffleUnlockedSlots`
/// and the legacy-CHOSEN center twins in `CenterSquare`. Mirrors
/// packages/bingo-core/tests/shuffle.test.ts + centerSquare.test.ts; the
/// byte-exact cross-platform pin is the `shuffleUnlockedVectors` fixture
/// driven by `BoardPlacementTests`.
final class ShuffleUnlockedTests: XCTestCase {

    private let slots: [String?] = ["a", "b", nil, "d", "FREE", "f", "g", nil, "i"]
    private let fixed: [Bool] = [true, false, false, false, true, false, false, false, false]

    private func seeded(_ seed: UInt32) -> () -> Double {
        var rng = SeededRng(seed: seed)
        return { rng.next() }
    }

    func test_fixedSlots_neverMove_acrossManySeeds() {
        for seed in UInt32(1)...200 {
            let result = Shuffle.shuffleUnlockedSlots(slots, fixed: fixed, rng: seeded(seed))
            XCTAssertEqual(result[0], "a")
            XCTAssertEqual(result[4], "FREE")
        }
    }

    func test_preservesMultisetOfUnfixedValues_emptiesIncluded() {
        let result = Shuffle.shuffleUnlockedSlots(slots, fixed: fixed, rng: seeded(7))
        func unfixed(_ arr: [String?]) -> [String] {
            arr.enumerated().filter { !fixed[$0.offset] }.map { $0.element ?? "<empty>" }.sorted()
        }
        XCTAssertEqual(result.count, slots.count)
        XCTAssertEqual(unfixed(result), unfixed(slots))
    }

    func test_emptiesMoveToo() {
        var moved = Set<Int>()
        for seed in UInt32(1)...50 {
            let result = Shuffle.shuffleUnlockedSlots(slots, fixed: fixed, rng: seeded(seed))
            for (i, v) in result.enumerated() where v == nil && slots[i] != nil { moved.insert(i) }
        }
        XCTAssertFalse(moved.isEmpty)
    }

    func test_allButOneFixed_isIdentity() {
        let allButOne = fixed.indices.map { $0 != 5 }
        XCTAssertEqual(Shuffle.shuffleUnlockedSlots(slots, fixed: allButOne, rng: seeded(11)), slots)
    }

    func test_equalsFisherYatesOverUnfixedValuesInAscendingOrder() {
        let unfixedIdx = fixed.indices.filter { !fixed[$0] }
        let expectedValues = Shuffle.fisherYatesShuffle(unfixedIdx.map { slots[$0] }, rng: seeded(42))
        let result = Shuffle.shuffleUnlockedSlots(slots, fixed: fixed, rng: seeded(42))
        XCTAssertEqual(unfixedIdx.map { result[$0] }, expectedValues)
    }

    func test_defaultRng_keepsFixedSlots() {
        let result = Shuffle.shuffleUnlockedSlots(slots, fixed: fixed)
        XCTAssertEqual(result[0], "a")
        XCTAssertEqual(result[4], "FREE")
        XCTAssertEqual(result.count, 9)
    }

    // MARK: - CenterSquare legacy-CHOSEN twins

    func test_effectiveCenter_mapsChosenToNone_passesOthersThrough() {
        XCTAssertEqual(CenterSquare.effectiveCenter(.chosen), .none)
        XCTAssertEqual(CenterSquare.effectiveCenter(.free), .free)
        XCTAssertEqual(CenterSquare.effectiveCenter(.none), .none)
    }

    func test_isLegacyChosen() {
        XCTAssertTrue(CenterSquare.isLegacyChosen(.chosen))
        XCTAssertFalse(CenterSquare.isLegacyChosen(.free))
        XCTAssertFalse(CenterSquare.isLegacyChosen(.none))
    }

    func test_isLegacyChosenCenterLocked() {
        XCTAssertTrue(CenterSquare.isLegacyChosenCenterLocked(centerType: .chosen, row: 2, col: 2, gridSize: 5))
        XCTAssertTrue(CenterSquare.isLegacyChosenCenterLocked(centerType: .chosen, row: 1, col: 1, gridSize: 3))
        XCTAssertFalse(CenterSquare.isLegacyChosenCenterLocked(centerType: .chosen, row: 0, col: 0, gridSize: 5))
        XCTAssertFalse(CenterSquare.isLegacyChosenCenterLocked(centerType: .chosen, row: 2, col: 1, gridSize: 5))
        XCTAssertFalse(CenterSquare.isLegacyChosenCenterLocked(centerType: .free, row: 2, col: 2, gridSize: 5))
        XCTAssertFalse(CenterSquare.isLegacyChosenCenterLocked(centerType: .none, row: 2, col: 2, gridSize: 5))
        XCTAssertFalse(CenterSquare.isLegacyChosenCenterLocked(centerType: .chosen, row: 2, col: 2, gridSize: 4))
        XCTAssertFalse(CenterSquare.isLegacyChosenCenterLocked(centerType: .chosen, row: 1, col: 1, gridSize: 4))
    }
}
