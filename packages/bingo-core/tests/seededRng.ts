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
 * **Deliberate duplicate.** The canonical copy is
 * `packages/shared/src/algorithms/seededRng.ts` (promoted there in B3, when
 * the wizard's Preview needed a seeded roll in PRODUCTION code). This file is
 * not a re-export of it: `@oybc/shared` depends on `@oybc/bingo-core`, so a
 * dependency the other way would be a package-graph cycle (the Play/Do
 * boundary guardrail — docs/ROADMAP.md Track G), and a relative import
 * reaching into another package's `src` is build-tool-fragile. The two copies
 * are pinned byte-for-byte by matching vector tests — `tests/seededRng.test.ts`
 * here and `tests/algorithms/seededRng.test.ts` in shared assert the SAME
 * literal sequences — so a silent divergence reds both suites.
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
