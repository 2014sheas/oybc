import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { RisoBoardCell, type BoardCellModel } from '../RisoBoardCell';
import styles from '../RisoBoard.module.css';

/**
 * Pins the dark-contract fix (2026-09 audit T1): the FREE center and the
 * done-cell check badge carry gold content, so their fills/keylines must use
 * the STATIC ink token — adaptive `--riso-ink` flips to cream in dark mode and
 * washes the gold out.
 *
 * The token itself can't be observed without a DOM + computed styles (this
 * harness is node-only), so this pins that the FREE and done cells render the
 * CSS-module classes whose rules carry the static token (`RisoBoard.module.css`
 * `.free`, `.check`, `.check svg`) — a refactor that routes FREE or the check
 * badge through a different class is caught here.
 */

function makeCell(over: Partial<BoardCellModel>): BoardCellModel {
  return {
    key: 'k',
    label: 'Walk',
    type: 'normal',
    done: false,
    isFree: false,
    isLine: false,
    ...over,
  };
}

function classesOf(html: string): string[] {
  const match = html.match(/^<div class="([^"]*)"/);
  return match ? match[1].split(' ') : [];
}

describe('RisoBoardCell — dark contract on gold content', () => {
  it('resolves real CSS-module class names (guards against vacuous matches)', () => {
    for (const name of [styles.free, styles.freeStar, styles.done, styles.check]) {
      expect(typeof name).toBe('string');
      expect(name.length).toBeGreaterThan(0);
    }
  });

  it('renders the FREE center with the .free class (and not .done)', () => {
    const html = renderToStaticMarkup(
      React.createElement(RisoBoardCell, { cell: makeCell({ key: 'free-12', label: 'FREE', isFree: true, done: true }) }),
    );
    const classes = classesOf(html);
    expect(classes).toContain(styles.free);
    expect(classes).not.toContain(styles.done);
    expect(html).toContain(`class="${styles.freeStar}"`);
  });

  it('renders a done cell with the .done class and the gold .check badge', () => {
    const html = renderToStaticMarkup(React.createElement(RisoBoardCell, { cell: makeCell({ done: true }) }));
    expect(classesOf(html)).toContain(styles.done);
    expect(html).toContain(`class="${styles.check}"`);
  });
});

describe('RisoBoardCell — lock + dirty chips (Board Edit redesign slice 3, D12)', () => {
  it('renders BOTH the lock and dirty chips, side by side, when a square is locked AND staged-dirty', () => {
    const html = renderToStaticMarkup(
      React.createElement(RisoBoardCell, { cell: makeCell({ locked: true, dirty: true }) }),
    );
    expect(html).toContain(`class="${styles.chipRow}"`);
    expect(html).toContain(`class="${styles.chip} ${styles.chipLock}"`);
    expect(html).toContain(`class="${styles.chip} ${styles.chipDirty}"`);
  });

  it('renders only the lock chip when locked and not dirty', () => {
    const html = renderToStaticMarkup(
      React.createElement(RisoBoardCell, { cell: makeCell({ locked: true, dirty: false }) }),
    );
    expect(html).toContain(`class="${styles.chip} ${styles.chipLock}"`);
    expect(html).not.toContain(styles.chipDirty);
  });

  it('renders only the dirty chip when dirty and not locked', () => {
    const html = renderToStaticMarkup(
      React.createElement(RisoBoardCell, { cell: makeCell({ locked: false, dirty: true }) }),
    );
    expect(html).toContain(`class="${styles.chip} ${styles.chipDirty}"`);
    expect(html).not.toContain(styles.chipLock);
  });

  it('renders no chip at all when neither locked nor dirty', () => {
    const html = renderToStaticMarkup(
      React.createElement(RisoBoardCell, { cell: makeCell({ locked: false, dirty: false }) }),
    );
    expect(html).not.toContain(styles.chipRow);
  });
});

describe('RisoBoardCell — counter kinds (C1: fit tiers, ×goal tag, gold overshoot)', () => {
  const renderCell = (over: Partial<BoardCellModel>, cellSize: number) =>
    renderToStaticMarkup(React.createElement(RisoBoardCell, { cell: makeCell({ type: 'counting', ...over }), cellSize }));

  it('an overshoot continuous cell keeps its real value, a gold bar and the ×goal tag', () => {
    const html = renderCell({ label: 'Run 26.2 mi', done: true, count: { cur: 28.4, max: 26.2, kind: 'continuous' } }, 90);
    expect(html).toContain('28.4/26.2');
    expect(html).toContain(`class="${styles.cbar} ${styles.over}"`);
    expect(html).toContain('×26.2');
  });

  it('a duration tag and the cur tier at 90px', () => {
    const html = renderCell({ label: 'Code 500h', count: { cur: 6735, max: 30000, kind: 'duration' } }, 90);
    expect(html).toContain('×500h');
    expect(html).toContain('>112h 15m<');
    expect(html).not.toContain('112h 15m/500h');
  });

  it('fill only when even cur does not fit', () => {
    const html = renderCell({ label: 'Code 500h', count: { cur: 6735, max: 30000, kind: 'duration' } }, 58);
    expect(html).not.toContain('112h');
  });

  it('a discrete cell under its goal keeps the plain blue bar', () => {
    const html = renderCell({ label: 'Read 5 pages', count: { cur: 3, max: 5, kind: 'discrete' } }, 90);
    expect(html).toContain(`class="${styles.cbar}"`);
    expect(html).toContain('>3/5<');
    expect(html).toContain('×5');
  });
});
