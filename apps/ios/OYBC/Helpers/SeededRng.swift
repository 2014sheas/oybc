import Foundation

/// SeededRng — the deterministic uniform `[0, 1)` source this repo uses
/// wherever a reproducible "random" sequence is needed.
///
/// Swift twin of `packages/shared/src/algorithms/seededRng.ts`
/// (`makeSeededRng`), pinned sample-for-sample by ``SeededRngTests`` against
/// the same vectors the shared suite asserts. The recurrence is the
/// Numerical Recipes LCG:
///
/// ```
/// state = (state * 1664525 + 1013904223) mod 2^32
/// sample = state / 2^32
/// ```
///
/// `UInt32` with wrapping arithmetic (`&*` / `&+`) is exactly what the TS
/// side emulates with `Math.imul` + `>>> 0`, which is what makes the two
/// byte-identical.
///
/// Promoted out of the three private test copies
/// (`BoardPlacementTests` / `BoardSourceVectorTests` /
/// `MemberRuleVectorTests`, which now delegate here) when a PRODUCTION
/// surface needed it: the wizard's Preview seeds its member-rule dry run
/// from the Shuffle nonce, so one nonce always previews the same targets
/// (docs/BOARD_SOURCES.md §Member rules; B3 RC6).
///
/// A `struct` with a `mutating func`, not a class: the state is a value and
/// callers that need a `() -> Double` capture a local `var` (see
/// ``makePreviewRng(shuffleNonce:)``).
struct SeededRng {

    /// The LCG's 32-bit state. Seeded directly; advanced by ``next()``.
    private var state: UInt32

    /// Creates a generator whose sequence is fully determined by `seed`.
    ///
    /// - Parameter seed: Unsigned 32-bit seed. The same seed always yields
    ///   the same sequence, on both platforms and in every test runner.
    init(seed: UInt32) {
        state = seed
    }

    /// Advances the generator and returns the next uniform sample.
    ///
    /// - Returns: A `Double` in `[0, 1)`.
    mutating func next() -> Double {
        state = state &* 1664525 &+ 1013904223
        return Double(state) / 4294967296.0
    }
}
