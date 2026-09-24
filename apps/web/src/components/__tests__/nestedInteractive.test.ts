import { describe, expect, it } from 'vitest';
import { findNestedInteractives } from './nestedInteractive';

describe('findNestedInteractives', () => {
  it('flags a button inside a role="button" wrapper — the audited shape', () => {
    const html =
      '<div role="button" aria-label="Row"><span>x</span><button aria-label="Remove">✕</button></div>';
    expect(findNestedInteractives(html)).toEqual(['<div "Row"> > <button "Remove">']);
  });

  it('flags a button inside a button and a link inside a button', () => {
    expect(findNestedInteractives('<button><button>a</button></button>')).toHaveLength(1);
    expect(findNestedInteractives('<button><a href="/x">a</a></button>')).toHaveLength(1);
  });

  it('passes sibling controls under a plain container, and closed scopes', () => {
    expect(
      findNestedInteractives(
        '<div><button aria-expanded="false">Row</button><button>✕</button></div><div role="button">y</div><button>z</button>',
      ),
    ).toEqual([]);
  });

  it('treats void inputs as leaves, not open scopes', () => {
    expect(findNestedInteractives('<label><input type="checkbox"/>a</label><button>b</button>')).toEqual([]);
  });
});
