import { makeSeededRng } from './seededRng';

/**
 * The same literals `packages/shared/tests/algorithms/seededRng.test.ts`
 * asserts against the canonical copy in
 * `packages/shared/src/algorithms/seededRng.ts`. This helper is a deliberate
 * duplicate (bingo-core must not depend on shared — see `seededRng.ts`'s
 * docstring), and these vectors are what stop the two drifting silently.
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

describe('makeSeededRng (bingo-core test helper) — matches the canonical copy', () => {
  it.each(Object.keys(VECTORS).map(Number))(
    'reproduces the pinned sequence for seed %i',
    (seed) => {
      const rng = makeSeededRng(seed);
      expect([rng(), rng(), rng(), rng(), rng()]).toEqual(VECTORS[seed]);
    },
  );
});
