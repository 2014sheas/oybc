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
}
