/**
 * Deterministic uniform [0,1) LCG (Numerical Recipes constants).
 *
 * Same seed ⇒ same sequence, in Jest and (ported identically) in XCTest.
 * This is the RNG every golden / cross-platform parity test in the Play
 * transition plan (PLAY_TRANSITION.md T2) feeds into `placeBoard` so the
 * TS and Swift suites can assert byte-identical expected arrays.
 *
 * Swift twin (see apps/ios/OYBC/OYBCTests/BoardPlacementTests.swift):
 *   state = state &* 1664525 &+ 1013904223   // wrapping UInt32
 *   return Double(state) / 4294967296.0
 *
 * Test helper only — intentionally NOT a `src` export.
 *
 * @param seed - Unsigned 32-bit seed.
 * @returns A function yielding successive uniform `[0, 1)` samples.
 */
export function makeSeededRng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 4294967296;
  };
}
