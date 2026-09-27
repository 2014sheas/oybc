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
    // Math.floor(rng() * (i + 1)) is uniform over [0, i]; the min-clamp
    // guards the rng() → (nearly) 1.0 edge (e.g. a buggy seeded LCG that can
    // return exactly 1.0) so the index never exceeds i. Mirrors the Swift
    // `Shuffle.fisherYatesShuffle`'s `min(j, i)` clamp (apps/ios/OYBC/Services/Shuffle.swift).
    const j = Math.min(Math.floor(rng() * (i + 1)), i);
    [result[i], result[j]] = [result[j], result[i]];
  }
  return result;
}

/**
 * Shuffle every non-fixed slot of a board, leaving fixed slots untouched.
 *
 * The squares editor's Shuffle (Board Edit slice 3, D10): locked placements
 * and the FREE center are `fixed`; every other slot — empties included, so an
 * empty square moves too — is permuted with {@link fisherYatesShuffle}. The
 * non-fixed indices are collected in ascending order, their values shuffled,
 * and written back to those same indices.
 *
 * Generic over `T` so this stays primitives-only (the Play boundary).
 * Deterministic under an injected `rng`; pinned cross-platform by
 * `shuffleUnlockedVectors` in `tests/fixtures/placementVectors.json`.
 * Swift twin: `Shuffle.shuffleUnlockedSlots(_:fixed:rng:)`.
 *
 * @param slots - Row-major slot values (`null` = empty square).
 * @param fixed - Parallel flags; `true` = the slot must not move.
 * @param rng - Optional uniform `[0, 1)` RNG. Defaults to `Math.random`.
 * @returns A new array; fixed slots keep their values, the rest are permuted.
 * @throws Error when `slots` and `fixed` differ in length.
 */
export function shuffleUnlockedSlots<T>(
  slots: ReadonlyArray<T | null>,
  fixed: ReadonlyArray<boolean>,
  rng: () => number = Math.random,
): (T | null)[] {
  if (slots.length !== fixed.length) {
    throw new Error(
      `shuffleUnlockedSlots: slots (${slots.length}) and fixed (${fixed.length}) lengths differ`,
    );
  }
  const unfixed: number[] = [];
  for (let i = 0; i < slots.length; i++) {
    if (!fixed[i]) unfixed.push(i);
  }
  const shuffled = fisherYatesShuffle(
    unfixed.map((i) => slots[i]),
    rng,
  );
  const result = [...slots];
  unfixed.forEach((slotIndex, k) => {
    result[slotIndex] = shuffled[k];
  });
  return result;
}
