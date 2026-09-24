import { describe, expect, it } from 'vitest';
import { nextTrappedFocusIndex } from '../useModalA11y';

/**
 * `useModalA11y` — the one modal contract every web dialog shares (2026-09
 * audit). The DOM half (initial focus, restore, the listener wiring) needs a
 * browser and is driven by `e2e/member-rules.spec.ts`; here we pin the pure
 * Tab-wrap decision, and guard that no dialog in `src/` bypasses the hook.
 */

describe('nextTrappedFocusIndex — the Tab trap', () => {
  it('wraps Tab from the last element back to the first', () => {
    expect(nextTrappedFocusIndex(3, 2, false)).toBe(0);
  });

  it('wraps Shift+Tab from the first element to the last', () => {
    expect(nextTrappedFocusIndex(3, 0, true)).toBe(2);
  });

  it('leaves a move between two inner elements to the browser', () => {
    expect(nextTrappedFocusIndex(3, 0, false)).toBeNull();
    expect(nextTrappedFocusIndex(3, 1, false)).toBeNull();
    expect(nextTrappedFocusIndex(3, 2, true)).toBeNull();
  });

  it('pulls focus that sits on no focusable element (the container) to an end', () => {
    expect(nextTrappedFocusIndex(4, -1, false)).toBe(0);
    expect(nextTrappedFocusIndex(4, -1, true)).toBe(3);
  });

  it('keeps focus on the only element of a one-control dialog', () => {
    expect(nextTrappedFocusIndex(1, 0, false)).toBe(0);
    expect(nextTrappedFocusIndex(1, 0, true)).toBe(0);
  });

  it('has nothing to move to in a dialog with no focusable element', () => {
    expect(nextTrappedFocusIndex(0, -1, false)).toBeNull();
    expect(nextTrappedFocusIndex(0, -1, true)).toBeNull();
  });
});

// ── Source guard: every dialog element spreads the hook's props ──────────────

// Every component's raw text via Vite's glob (no node builtins — the web
// tsconfig has no node types; same pattern as `dbBoundary.test.ts`). Keys are
// project-root-relative, e.g. `/src/pages/ProfilePage.tsx`.
const sources = import.meta.glob('/src/**/*.tsx', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

/**
 * The JSX opening tag around `index`: back to its `<`, forward to the `>`
 * that closes it at brace depth 0 (attribute expressions contain `=>`).
 */
function openingTagAt(source: string, index: number): string {
  const start = source.lastIndexOf('<', index);
  let depth = 0;
  for (let i = index; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') depth -= 1;
    else if (ch === '>' && depth === 0) return source.slice(start, i + 1);
  }
  return source.slice(start);
}

/** Every `role="dialog"` / `role="alertdialog"` JSX attribute outside comments. */
function dialogRoleSites(source: string): number[] {
  const sites: number[] = [];
  const re = /role="(?:alert)?dialog"/g;
  for (let m = re.exec(source); m !== null; m = re.exec(source)) {
    const lineStart = source.lastIndexOf('\n', m.index) + 1;
    const line = source.slice(lineStart, m.index).trimStart();
    if (line.startsWith('*') || line.startsWith('//') || line.includes('`')) continue;
    sites.push(m.index);
  }
  return sites;
}

describe('no dialog bypasses useModalA11y', () => {
  const offenders: string[] = [];
  let siteCount = 0;

  for (const [file, source] of Object.entries(sources)) {
    const sites = dialogRoleSites(source);
    if (sites.length === 0) continue;
    // Prop bags destructured from the hook in this file.
    const bags = [...source.matchAll(/props:\s*(\w+)\s*\}\s*=\s*useModalA11y\b/g)].map(
      (m) => m[1],
    );
    for (const site of sites) {
      siteCount += 1;
      const tag = openingTagAt(source, site);
      const spreadsHook = bags.some((bag) => tag.includes(`{...${bag}}`));
      if (!spreadsHook) offenders.push(`${file}: ${tag.split('\n')[0]}`);
    }
  }

  it('finds the dialogs it is guarding (the scan is not vacuous)', () => {
    expect(siteCount).toBeGreaterThanOrEqual(30);
  });

  it('every role="dialog" / role="alertdialog" element spreads useModalA11y props', () => {
    expect(offenders).toEqual([]);
  });
});
