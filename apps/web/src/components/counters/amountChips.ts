/**
 * amountChips.ts — pure helpers backing the Counter Detail Log card's
 * amount-chip row (R2 Counters UX refresh — design handoff §Counter Detail,
 * chips "1 / {default} / 25 / #"). Kept side-effect-free so the chip-set
 * shape and the custom-input validation are unit-testable without a DOM or
 * a Dexie transaction.
 */

/**
 * One chip in the amount row. `value` is the literal log amount for the
 * three fixed/derived chips; the trailing "#" (custom) chip carries `null`
 * — its actual amount comes from the user's typed input, tracked
 * separately by the caller.
 */
export interface AmountChipOption {
  value: number | null;
  label: string;
}

/**
 * Builds the fixed four-chip row: `1`, the counter's current default
 * amount, `25`, and the custom "#" chip.
 *
 * `defaultAmount` is rendered verbatim even when it collides with `1` or
 * `25` (e.g. a fresh counter defaults to `1`) — the design's chip set is a
 * fixed four positions, not a deduped set; a collision just means two
 * chips show the same number, which is harmless (both log the same
 * amount).
 *
 * @param defaultAmount The counter's current default log amount (positive
 *   integer; callers pass `group.defaultLogAmount ?? 1`).
 */
export function buildAmountChipOptions(defaultAmount: number): AmountChipOption[] {
  return dedupeChips([
    { value: 1, label: '1' },
    { value: defaultAmount, label: String(defaultAmount) },
    { value: 25, label: '25' },
    { value: null, label: '#' },
  ]);
}

/**
 * Drops chips whose `value` duplicates an earlier chip (keep-first). A fresh
 * counter's default is 1, which would otherwise render two "1"/"+1" chips
 * side by side (device-testing feedback, R3) — the design's "fixed positions"
 * intent doesn't survive contact with a literal duplicate. Selection logic on
 * both platforms resolves by first matching index, so dropping later
 * duplicates is behavior-neutral.
 */
function dedupeChips(chips: AmountChipOption[]): AmountChipOption[] {
  const seen = new Set<number>();
  return chips.filter((chip) => {
    if (chip.value === null) return true;
    if (seen.has(chip.value)) return false;
    seen.add(chip.value);
    return true;
  });
}

/**
 * Builds the board-play square quick-action chip row (R3 — Counters Refresh
 * board-play touchpoints): `1`, the counter's current default amount, and
 * the custom "#" chip.
 *
 * Deliberately a 3-position row, unlike `buildAmountChipOptions`'s 4 (no
 * fixed `25` chip) — the handoff spec's board-square mock shows only
 * `1 / {default} / #` for the in-context quick actions on a shared counting
 * square's detail modal / context menu; the full `1 / {default} / 25 / #`
 * row stays exclusive to Counter Detail's Log card.
 *
 * @param defaultAmount The counter's current default log amount (positive
 *   integer; callers pass the source task's `defaultLogAmount ?? 1`).
 */
export function buildBoardQuickAmountOptions(defaultAmount: number): AmountChipOption[] {
  // Board chips are SIGNED ("+1 / +{default} / #") per the R3 contract —
  // unlike Detail's unsigned "1 / {default} / 25 / #" row — because on the
  // board the chips drive both add and remove, and the handoff mock shows
  // the signed form. iOS's stepper-sheet chips match this exactly.
  return dedupeChips([
    { value: 1, label: '+1' },
    { value: defaultAmount, label: `+${defaultAmount}` },
    { value: null, label: '#' },
  ]);
}

/**
 * Validates a raw custom-amount input string into a positive integer, or
 * `null` when the input isn't one (empty, non-numeric, zero, negative,
 * fractional, or leading/trailing junk).
 *
 * Intentionally strict (`^\d+$` on the trimmed string) — no leading `+`/`-`,
 * no decimal point, no scientific notation, no whitespace mid-string.
 *
 * @param raw The custom-input field's current text value.
 */
export function parseCustomLogAmount(raw: string): number | null {
  const trimmed = raw.trim();
  if (!/^\d+$/.test(trimmed)) return null;
  const n = Number(trimmed);
  if (!Number.isInteger(n) || n <= 0) return null;
  return n;
}
