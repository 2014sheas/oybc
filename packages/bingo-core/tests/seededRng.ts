/**
 * Deterministic uniform [0,1) LCG (Numerical Recipes constants).
 *
 * Re-export only — the single implementation now lives in
 * `packages/shared/src/algorithms/seededRng.ts`, promoted out of this file
 * when the wizard's Preview needed a seeded roll in PRODUCTION code (B3
 * RC6). Kept here so the bingo-core suites that already import
 * `./seededRng` keep working, and so the repo holds exactly ONE LCG for the
 * Swift twin to stay byte-identical to.
 *
 * A source-relative import rather than a package dependency: `@oybc/shared`
 * depends on `@oybc/bingo-core`, so a real dependency the other way would be
 * a package-graph cycle. `seededRng.ts` imports nothing at all, so pulling
 * it in from a test file creates no module cycle — and the mirror import
 * already exists in the other direction
 * (`packages/shared/tests/algorithms/memberRules.test.ts` imports this file).
 */
export { makeSeededRng } from '../../shared/src/algorithms/seededRng';
