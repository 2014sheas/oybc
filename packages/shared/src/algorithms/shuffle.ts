/**
 * Fisher-Yates (Knuth) shuffle algorithm.
 *
 * Produces an unbiased permutation of the input array. Every permutation
 * is equally likely. The algorithm runs in O(n) time and O(n) space
 * (a copy is made so the original array is not mutated).
 *
 * This implementation is used on both web and iOS (mirrored in Swift)
 * to ensure identical shuffle behaviour across platforms.
 *
 * @param array - The array to shuffle
 * @param rng - Optional uniform `[0, 1)` RNG. Defaults to `Math.random`.
 *              Pass a seeded RNG from tests to make placement deterministic
 *              (Phase 6.2 spawn placement tests rely on this).
 * @returns A new array with the same elements in a random order
 */
export function fisherYatesShuffle<T>(
  array: ReadonlyArray<T>,
  rng: () => number = Math.random,
): T[] {
  const result = [...array];
  for (let i = result.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [result[i], result[j]] = [result[j], result[i]];
  }
  return result;
}
