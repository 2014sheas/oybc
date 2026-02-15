import Foundation

/// Shuffle algorithms for OYBC boards.
///
/// Provides the Fisher-Yates (Knuth) shuffle to randomize board task names.
/// Mirrors the TypeScript implementation in `packages/shared` for
/// cross-platform consistency.
enum Shuffle {

    /// Fisher-Yates (Knuth) shuffle algorithm.
    ///
    /// Produces an unbiased permutation of the input array. Every permutation
    /// is equally likely. The algorithm runs in O(n) time and O(n) space
    /// (a copy is made so the original array is not mutated).
    ///
    /// - Parameter array: The array to shuffle
    /// - Returns: A new array with the same elements in a random order
    static func fisherYatesShuffle<T>(_ array: [T]) -> [T] {
        var result = array
        for i in stride(from: result.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            result.swapAt(i, j)
        }
        return result
    }
}
