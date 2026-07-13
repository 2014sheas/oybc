import { describe, expect, it } from 'vitest';
import { POOL_PREVIEW_LIMIT, computePoolPreview } from './poolPreview';

describe('computePoolPreview', () => {
  const taskMap = {
    a: { title: 'Run 5k' },
    b: { title: 'Read a chapter' },
    c: { title: 'Meditate' },
    d: { title: 'Stretch' },
  };

  it('returns resolved titles in seedTaskIds order', () => {
    expect(computePoolPreview(['b', 'a'], taskMap)).toEqual({
      titles: ['Read a chapter', 'Run 5k'],
      overflow: 0,
    });
  });

  it('caps titles at the preview limit and reports resolved overflow', () => {
    expect(computePoolPreview(['a', 'b', 'c', 'd'], taskMap)).toEqual({
      titles: ['Run 5k', 'Read a chapter', 'Meditate'],
      overflow: 1,
    });
    expect(POOL_PREVIEW_LIMIT).toBe(3);
  });

  it('skips unresolvable ids without consuming a slot or counting toward overflow', () => {
    expect(
      computePoolPreview(['missing-1', 'a', 'missing-2', 'b', 'c'], taskMap),
    ).toEqual({
      titles: ['Run 5k', 'Read a chapter', 'Meditate'],
      overflow: 0,
    });
  });

  it('returns empty for an empty pool or fully unresolvable pool', () => {
    expect(computePoolPreview([], taskMap)).toEqual({ titles: [], overflow: 0 });
    expect(computePoolPreview(['x', 'y'], taskMap)).toEqual({
      titles: [],
      overflow: 0,
    });
  });

  it('respects an explicit limit', () => {
    expect(computePoolPreview(['a', 'b', 'c'], taskMap, 1)).toEqual({
      titles: ['Run 5k'],
      overflow: 2,
    });
  });
});
