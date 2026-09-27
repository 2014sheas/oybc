import Foundation

/// Shuffle algorithms for OYBC boards.
///
/// Provides the Fisher-Yates (Knuth) shuffle to randomize board task order.
/// Mirrors the TypeScript implementation in `@oybc/bingo-core`
/// (`src/shuffle.ts`) for cross-platform consistency. See
/// packages/bingo-core/MIRRORS.md.
enum Shuffle {

    /// Fisher-Yates (Knuth) shuffle with an injectable uniform `[0, 1)` RNG.
    ///
    /// Canonical variant: produces an unbiased permutation, runs in O(n) time
    /// and O(n) space (the input is copied, never mutated). The RNG hook makes
    /// placement deterministic in tests / server-side fan-out — Swift's
    /// `.shuffled()` doesn't expose one. Mirrors the TS
    /// `fisherYatesShuffle(arr, rng?)`.
    ///
    /// - Parameters:
    ///   - array: The array to shuffle.
    ///   - rng: Uniform `[0, 1)` generator (e.g. a seeded LCG in tests).
    /// - Returns: A new array with the same elements in a random order.
    static func fisherYatesShuffle<T>(
        _ array: [T],
        rng: () -> Double
    ) -> [T] {
        var result = array
        var i = result.count - 1
        while i > 0 {
            // Int(rng() * (i+1)) is uniform over [0, i]; the min-clamp guards
            // the rng()→(nearly 1.0) edge so the index never exceeds i.
            let j = Int(rng() * Double(i + 1))
            let clamped = min(j, i)
            result.swapAt(i, clamped)
            i -= 1
        }
        return result
    }

    /// Convenience overload using Foundation's system RNG (`Double.random`).
    /// Production randomization now routes through `BoardPlacement.placeBoard`'s
    /// rng default; this overload remains for tests and ad-hoc callers.
    ///
    /// - Parameter array: The array to shuffle.
    /// - Returns: A new array with the same elements in a random order.
    static func fisherYatesShuffle<T>(_ array: [T]) -> [T] {
        fisherYatesShuffle(array, rng: { Double.random(in: 0..<1) })
    }

    /// Shuffle every non-fixed slot of a board, leaving fixed slots untouched.
    ///
    /// The squares editor's Shuffle (Board Edit slice 3, D10): locked
    /// placements and the FREE center are `fixed`; every other slot — empties
    /// included, so an empty square moves too — is permuted with
    /// ``fisherYatesShuffle(_:rng:)``. The non-fixed indices are collected in
    /// ascending order, their values shuffled, and written back to those same
    /// indices. Twin of `@oybc/bingo-core` `shuffleUnlockedSlots`; pinned
    /// cross-platform by `shuffleUnlockedVectors` in `placementVectors.json`.
    ///
    /// The TS twin throws on a length mismatch; here it is a programmer error
    /// and traps via `precondition` (callers build both arrays from one grid).
    ///
    /// - Parameters:
    ///   - slots: Row-major slot values (`nil` = empty square).
    ///   - fixed: Parallel flags; `true` = the slot must not move.
    ///   - rng: Uniform `[0, 1)` generator. Defaults to the system RNG.
    /// - Returns: A new array; fixed slots keep their values, the rest are permuted.
    static func shuffleUnlockedSlots<T>(
        _ slots: [T?],
        fixed: [Bool],
        rng: () -> Double = { Double.random(in: 0..<1) }
    ) -> [T?] {
        precondition(
            slots.count == fixed.count,
            "shuffleUnlockedSlots: slots (\(slots.count)) and fixed (\(fixed.count)) lengths differ"
        )
        let unfixed = slots.indices.filter { !fixed[$0] }
        let shuffled = fisherYatesShuffle(unfixed.map { slots[$0] }, rng: rng)
        var result = slots
        for (k, slotIndex) in unfixed.enumerated() {
            result[slotIndex] = shuffled[k]
        }
        return result
    }
}
