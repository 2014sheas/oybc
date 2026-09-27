import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { ArrangeGrid, type ArrangeSlot } from '../ArrangeGrid';
import { freeCellModel } from '../../board/cellModel';

/**
 * The Rearrange jiggle is a CSS class (`.jiggle`), applied per cell only
 * while `rearrange` is true — so leaving Rearrange removes it and the cell
 * rests at rotate(0). Pins that gating (the iOS twin had a bug where the
 * shake outlived the mode). Movable, non-empty cells jiggle; the center
 * never does.
 */

function slots(): ArrangeSlot[] {
  return Array.from({ length: 9 }, (_, i) => ({
    cid: `c${i}`,
    isCenter: i === 4,
    isEmpty: false,
    model: freeCellModel(`c${i}`, `Cell ${i}`),
  }));
}

function jigglingCellCount(rearrange: boolean): number {
  const html = renderToStaticMarkup(
    React.createElement(ArrangeGrid, {
      slots: slots(),
      gridSize: 3,
      rearrange,
      onReorder: () => undefined,
    }),
  );
  return (html.match(/class="[^"]*jiggle[^"]*"/g) ?? []).length;
}

describe('ArrangeGrid jiggle gating', () => {
  it('jiggles every movable cell (not the center) in Rearrange', () => {
    expect(jigglingCellCount(true)).toBe(8);
  });

  it('applies no jiggle class once Rearrange is off', () => {
    expect(jigglingCellCount(false)).toBe(0);
  });
});
