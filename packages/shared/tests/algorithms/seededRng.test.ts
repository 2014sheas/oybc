import { makeSeededRng } from '../../src/algorithms/seededRng';

/**
 * The seeded-LCG vectors.
 *
 * `makeSeededRng` exists TWICE on purpose — canonically here in
 * `packages/shared/src/algorithms/seededRng.ts` (production: the wizard
 * Preview's seeded roll) and as a test helper in
 * `packages/bingo-core/tests/seededRng.ts`, because `@oybc/shared` depends on
 * `@oybc/bingo-core` and a dependency the other way would be a package-graph
 * cycle (docs/ROADMAP.md Track G's Play/Do boundary). The SAME literals are
 * asserted by `packages/bingo-core/tests/seededRng.test.ts`, so the two
 * copies — and the Swift twin, which ports the same recurrence — cannot drift
 * silently. A change to either copy reds both suites.
 *
 * The recurrence: `state = (state * 1664525 + 1013904223) mod 2^32`, sample =
 * `state / 2^32`, `state` seeded with `seed >>> 0`.
 */
const VECTORS: Record<number, number[]> = {
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
};

describe("makeSeededRng — the repo's one production LCG", () => {
  it.each(Object.keys(VECTORS).map(Number))(
    'reproduces the pinned sequence for seed %i',
    (seed) => {
      const rng = makeSeededRng(seed);
      expect([rng(), rng(), rng(), rng(), rng()]).toEqual(VECTORS[seed]);
    },
  );

  it('yields samples in [0, 1) and reproduces per seed', () => {
    const a = makeSeededRng(12345);
    const b = makeSeededRng(12345);
    for (let i = 0; i < 200; i += 1) {
      const sample = a();
      expect(sample).toBeGreaterThanOrEqual(0);
      expect(sample).toBeLessThan(1);
      expect(sample).toBe(b());
    }
  });
});
