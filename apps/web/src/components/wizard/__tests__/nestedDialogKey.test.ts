import { describe, expect, it } from 'vitest';
import { isNestedDialogKey } from '../nestedDialogKey';

/**
 * The wizard's inline row editor (`PoolRowEditor`) listens for Escape
 * (discard) and ⌘↵ (save) at its root. Keys from the "+ Existing task…"
 * picker nested inside it must not reach those shortcuts, but keys from the
 * editor's own controls must — including the threshold `CounterStepper`,
 * which preventDefaults its own Enter. Fake event objects (no DOM in this
 * harness): `closest` stands in for the target's nearest `aria-modal`.
 */

const editorRoot = { id: 'editor' };
const picker = { id: 'picker' };

function key(
  k: string,
  opts: { defaultPrevented?: boolean; inPicker?: boolean } = {},
): Parameters<typeof isNestedDialogKey>[0] {
  const nested = opts.inPicker ? picker : null;
  return {
    key: k,
    defaultPrevented: opts.defaultPrevented ?? false,
    target: { closest: () => nested } as unknown as EventTarget,
    // The picker renders inside the editor, so the editor contains it.
    currentTarget: { contains: (node: Node | null) => node === (picker as unknown as Node) || node === (editorRoot as unknown as Node) },
  };
}

describe('isNestedDialogKey (PoolRowEditor shortcut guard)', () => {
  it('ignores the Escape the picker already consumed — the row editor stays open', () => {
    expect(isNestedDialogKey(key('Escape', { defaultPrevented: true, inPicker: true }))).toBe(true);
  });

  it('ignores any key typed inside the picker (⌘↵ in its search does not save)', () => {
    expect(isNestedDialogKey(key('Enter', { inPicker: true }))).toBe(true);
  });

  it('keeps ⌘↵ from the threshold stepper, which preventDefaults its Enter — the row still saves', () => {
    expect(isNestedDialogKey(key('Enter', { defaultPrevented: true }))).toBe(false);
  });

  it('ignores an Escape a nested dialog consumed even when the target is outside it', () => {
    expect(isNestedDialogKey(key('Escape', { defaultPrevented: true, inPicker: false }))).toBe(true);
  });

  it('keeps a plain Escape from the editor itself — it still discards', () => {
    expect(isNestedDialogKey(key('Escape'))).toBe(false);
  });
});
