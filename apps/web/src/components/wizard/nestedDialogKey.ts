/**
 * Whether a key reaching the row editor belongs to a dialog nested inside it
 * (the "+ Existing task…" picker): an Escape a nested `useModalA11y` already
 * consumed (`preventDefault`), or any key whose target sits in a nested
 * `aria-modal` element. Only ESCAPE is checked for `defaultPrevented` — other
 * controls (the threshold `CounterStepper`) preventDefault their own Enter,
 * and ⌘↵ from them must still save the row.
 *
 * @param e - The keydown event at the editor root.
 * @returns `true` when the editor must ignore the key.
 */
export function isNestedDialogKey(e: {
  key: string;
  defaultPrevented: boolean;
  target: EventTarget | null;
  currentTarget: { contains: (node: Node | null) => boolean };
}): boolean {
  if (e.key === 'Escape' && e.defaultPrevented) return true;
  const target = e.target as HTMLElement | null;
  const nestedModal = target?.closest?.('[aria-modal="true"]') ?? null;
  return nestedModal !== null && e.currentTarget.contains(nestedModal);
}
