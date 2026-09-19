/**
 * seededRng.ts — the one deterministic uniform `[0, 1)` LCG this repo uses
 * wherever a reproducible "random" sequence is needed.
 *
 * Promoted out of `packages/bingo-core/tests/seededRng.ts` (which now
 * re-exports this module) when a PRODUCTION surface needed it: the wizard's
 * Preview seeds its member-rule dry run from the Shuffle nonce, so the same
 * nonce always previews the same targets (docs/BOARD_SOURCES.md §Member
 * rules; B3 RC6). The golden / cross-platform parity tests keep feeding the
 * same function into `placeBoard` and `planDerivedTasks`, so one seed still
 * means one sequence everywhere.
 *
 * Swift twin (`apps/ios/OYBCTests/BoardPlacementTests.swift`, and B3 Task 8's
 * `SeededRng`):
 *
 * ```swift
 * state = state &* 1664525 &+ 1013904223   // wrapping UInt32
 * return Double(state) / 4294967296.0
 * ```
 *
 * Numerical Recipes constants; `Math.imul` + `>>> 0` keep the state a true
 * unsigned 32-bit wrap, which is what makes the Swift port byte-identical.
 */

/**
 * A deterministic uniform `[0, 1)` source.
 *
 * @param seed - Unsigned 32-bit seed. The same seed always yields the same
 *   sequence, on both platforms and in every test runner.
 * @returns A function yielding successive uniform `[0, 1)` samples.
 */
export function makeSeededRng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 4294967296;
  };
}
