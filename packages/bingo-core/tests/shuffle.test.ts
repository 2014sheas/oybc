import { fisherYatesShuffle } from '../src/shuffle';

describe('fisherYatesShuffle', () => {
  it('returns an empty array when given an empty array', () => {
    expect(fisherYatesShuffle([])).toEqual([]);
  });

  it('returns a single-element array unchanged', () => {
    expect(fisherYatesShuffle([42])).toEqual([42]);
  });

  it('returns an array with the same length', () => {
    const input = [1, 2, 3, 4, 5];
    const result = fisherYatesShuffle(input);
    expect(result).toHaveLength(input.length);
  });

  it('contains all original elements (no duplicates, no missing)', () => {
    const input = ['a', 'b', 'c', 'd', 'e'];
    const result = fisherYatesShuffle(input);
    expect(result.sort()).toEqual([...input].sort());
  });

  it('does not mutate the original array', () => {
    const input = [1, 2, 3, 4, 5];
    const copy = [...input];
    fisherYatesShuffle(input);
    expect(input).toEqual(copy);
  });

  it('works with different types (strings)', () => {
    const input = ['Task 1', 'Task 2', 'Task 3'];
    const result = fisherYatesShuffle(input);
    expect(result.sort()).toEqual([...input].sort());
  });

  it('works with objects', () => {
    const a = { id: 1 };
    const b = { id: 2 };
    const c = { id: 3 };
    const input = [a, b, c];
    const result = fisherYatesShuffle(input);
    expect(result).toHaveLength(3);
    expect(result).toContain(a);
    expect(result).toContain(b);
    expect(result).toContain(c);
  });

  it('handles a two-element array', () => {
    const input = [1, 2];
    const result = fisherYatesShuffle(input);
    expect(result.sort()).toEqual([1, 2]);
  });

  it('handles large arrays correctly (25 elements for 5x5 board)', () => {
    const input = Array.from({ length: 25 }, (_, i) => `Task ${i + 1}`);
    const result = fisherYatesShuffle(input);
    expect(result).toHaveLength(25);
    expect(result.sort()).toEqual([...input].sort());
  });

  it('produces different orderings (statistical test)', () => {
    // Run 100 shuffles of a 5-element array and verify
    // not all results are identical (would be astronomically unlikely
    // with a working shuffle: 1/5!^99 chance of all identical)
    const input = [1, 2, 3, 4, 5];
    const results = new Set<string>();

    for (let i = 0; i < 100; i++) {
      results.add(JSON.stringify(fisherYatesShuffle(input)));
    }

    // With 100 shuffles of 5 elements (120 permutations),
    // we should see at least 2 distinct orderings
    expect(results.size).toBeGreaterThan(1);
  });

  it('distributes elements roughly uniformly (chi-squared-like test)', () => {
    // Shuffle [0, 1, 2, 3, 4] many times and count how often
    // each element lands in position 0. With uniform distribution
    // each element should appear ~20% of the time.
    const n = 5;
    const trials = 10000;
    const counts: Record<number, number> = {};
    for (let v = 0; v < n; v++) counts[v] = 0;

    for (let t = 0; t < trials; t++) {
      const result = fisherYatesShuffle([0, 1, 2, 3, 4]);
      counts[result[0]]++;
    }

    const expected = trials / n; // 2000
    for (let v = 0; v < n; v++) {
      // Allow 30% deviation from expected (generous for randomness)
      expect(counts[v]).toBeGreaterThan(expected * 0.7);
      expect(counts[v]).toBeLessThan(expected * 1.3);
    }
  });

  it('accepts readonly arrays', () => {
    const input: readonly number[] = [1, 2, 3];
    const result = fisherYatesShuffle(input);
    expect(result.sort()).toEqual([1, 2, 3]);
  });

  // Board-integrity PR-5 (issue #362), Item 2: an rng() returning exactly
  // 1.0 (possible from a buggy seeded LCG — the Numerical Recipes LCG in
  // seededRng.ts / BoardPlacementTests.swift is mod-2^32 and so in principle
  // CAN emit state=0 → 0/4294967296 = 0, but a hostile/adversarial rng could
  // just as easily emit 1.0 directly) must not push the swap index out of
  // bounds. Swift's `Shuffle.fisherYatesShuffle` already clamps via
  // `min(j, i)`; this pins the TS side to the same behavior instead of
  // silently reading/writing `result[i + 1]` (undefined at the top of the
  // array, and a real out-of-bounds write for smaller arrays).
  it('clamps an adversarial rng() that returns exactly 1.0 (no out-of-bounds index)', () => {
    const alwaysOne = () => 1.0;
    const input = [0, 1, 2, 3, 4];
    // Without the min(j, i) clamp, Math.floor(1.0 * (i + 1)) === i + 1 for
    // every i, so result[i + 1] would be swapped in instead of result[i]:
    // an out-of-bounds read/write (undefined at i = length - 1, and a
    // silent no-op — not even a shuffle — for the rest).
    const result = fisherYatesShuffle(input, alwaysOne);
    expect(result).toHaveLength(5);
    expect(result.every((v) => v !== undefined)).toBe(true);
    expect([...result].sort()).toEqual([0, 1, 2, 3, 4]);
  });

  it('an adversarial rng() returning 1.0 clamps to swapping with self (identity at the clamped index)', () => {
    // With j clamped to i, result[i] <-> result[j] is a self-swap at every
    // step, so the array comes back in ORIGINAL order — pinning the exact
    // clamped semantics, not just "doesn't crash".
    const alwaysOne = () => 1.0;
    const input = ['a', 'b', 'c', 'd', 'e'];
    const result = fisherYatesShuffle(input, alwaysOne);
    expect(result).toEqual(input);
  });
});
