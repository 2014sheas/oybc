/**
 * counterStepperMath.ts — the compact stepper's pure arithmetic, lifted out
 * of `CounterStepper.tsx`. Twin of iOS's `RisoCompactStepperMath` enum,
 * which exists for the same reason: the rule is testable without mounting
 * a view.
 */

/**
 * The number the compact −/+ buttons gate their `disabled` state by: the
 * uncommitted draft when it parses, else the live value. Twin of iOS
 * `RisoCompactStepperMath.base(value:draft:min:max:)`.
 *
 * Without it, typing `1` into a `min: 1` field leaves `−` enabled until
 * blur — the control offers an action its own commit would immediately
 * clamp away. (Only the GATING needs this on web: a mousedown blurs the
 * `<input>`, so `onBlur` commits and re-renders before `onClick` steps,
 * which is why the step handlers read `value` directly.)
 *
 * Its own module (not an export off `CounterStepper.tsx`) so the component
 * file keeps exporting only a component (`react-refresh/only-export-components`),
 * and so the node-env Vitest harness can pin it without a DOM: the server
 * render never has a draft.
 *
 * @param value - The committed value.
 * @param draft - The uncommitted field text, or `null` when not editing.
 * @param min - Lower bound (inclusive).
 * @param max - Upper bound (inclusive).
 * @returns The effective value, clamped to `[min, max]`.
 */
export function compactStepperBase(
  value: number,
  draft: string | null,
  min: number,
  max: number,
): number {
  if (draft === null) return value;
  const parsed = Number.parseInt(draft.trim(), 10);
  if (!Number.isFinite(parsed)) return value;
  return Math.min(max, Math.max(min, parsed));
}
