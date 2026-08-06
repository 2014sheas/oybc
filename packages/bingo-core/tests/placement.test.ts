import { placeBoard, fillableCellCount } from '../src/placement';
import { CenterSquareType } from '../src/constants';
import { makeSeededRng } from './seededRng';

// ─── Fixtures ─────────────────────────────────────────────────────────────────

interface Item {
  id: string;
}

/** Builds `count` items with ids `i0..i{count-1}`. */
function items(count: number): Item[] {
  return Array.from({ length: count }, (_, i) => ({ id: `i${i}` }));
}

/** Maps a placement to a compact id/`_` array for readable assertions. */
function ids(placement: (Item | null)[]): string[] {
  return placement.map((t) => t?.id ?? '_');
}

// ─── fillableCellCount ────────────────────────────────────────────────────────

describe('fillableCellCount', () => {
  it('5x5 FREE reserves the center → 24', () => {
    expect(fillableCellCount(5, CenterSquareType.FREE)).toBe(24);
  });

  it('5x5 CHOSEN / NONE fill the center → 25', () => {
    expect(fillableCellCount(5, CenterSquareType.CHOSEN)).toBe(25);
    expect(fillableCellCount(5, CenterSquareType.NONE)).toBe(25);
  });

  it('3x3 FREE reserves the center → 8; NONE → 9', () => {
    expect(fillableCellCount(3, CenterSquareType.FREE)).toBe(8);
    expect(fillableCellCount(3, CenterSquareType.NONE)).toBe(9);
  });

  it('4x4 even board has no center → 16 regardless of center type', () => {
    expect(fillableCellCount(4, CenterSquareType.FREE)).toBe(16);
    expect(fillableCellCount(4, CenterSquareType.CHOSEN)).toBe(16);
    expect(fillableCellCount(4, CenterSquareType.NONE)).toBe(16);
  });
});

// ─── placeBoard: center handling ──────────────────────────────────────────────

describe('placeBoard center handling', () => {
  it('5x5 FREE leaves index 12 null and places 24 of 25', () => {
    const placement = placeBoard({
      items: items(24),
      gridSize: 5,
      centerType: CenterSquareType.FREE,
      randomize: false,
    });
    expect(placement).toHaveLength(25);
    expect(placement[12]).toBeNull();
    expect(placement[0]?.id).toBe('i0');
    expect(placement[11]?.id).toBe('i11');
    expect(placement[13]?.id).toBe('i12'); // skipped center
    const placed = placement.flatMap((t) => (t ? [t.id] : []));
    expect(placed).toHaveLength(24);
  });

  it('5x5 CHOSEN pins the id at center and never duplicates it elsewhere', () => {
    const placement = placeBoard({
      items: items(25),
      gridSize: 5,
      centerType: CenterSquareType.CHOSEN,
      chosenCenterId: 'i7',
      randomize: false,
    });
    expect(placement[12]?.id).toBe('i7');
    const others = placement
      .filter((_, idx) => idx !== 12)
      .flatMap((t) => (t ? [t.id] : []));
    expect(others).not.toContain('i7');
    // 24 remaining items fill the 24 non-center cells.
    expect(others).toHaveLength(24);
  });

  it('5x5 CHOSEN with an unresolvable id falls back to an ordinary center', () => {
    const placement = placeBoard({
      items: items(25),
      gridSize: 5,
      centerType: CenterSquareType.CHOSEN,
      chosenCenterId: 'does-not-exist',
      randomize: false,
    });
    // Center is treated as ordinary → next pool item lands there, all 25 placed.
    expect(placement[12]?.id).toBe('i12');
    expect(placement.every((t) => t !== null)).toBe(true);
  });

  it('5x5 NONE fills all 25 cells including the center', () => {
    const placement = placeBoard({
      items: items(25),
      gridSize: 5,
      centerType: CenterSquareType.NONE,
      randomize: false,
    });
    expect(placement).toHaveLength(25);
    expect(placement.every((t) => t !== null)).toBe(true);
    expect(placement[12]?.id).toBe('i12');
  });

  it('4x4 ignores centerType entirely — no reserved center, all 16 filled', () => {
    const placement = placeBoard({
      items: items(16),
      gridSize: 4,
      centerType: CenterSquareType.FREE,
      chosenCenterId: 'i0',
      randomize: false,
    });
    expect(placement).toHaveLength(16);
    expect(placement.every((t) => t !== null)).toBe(true);
    // Even grid: no pin, order preserved verbatim.
    expect(ids(placement)).toEqual(items(16).map((t) => t.id));
  });
});

// ─── placeBoard: pool fit ─────────────────────────────────────────────────────

describe('placeBoard pool fit', () => {
  it('underfilled pool leaves trailing nulls in the right cells', () => {
    // 5 items on a 3x3 NONE (9 cells) → cells 0..4 filled, 5..8 null.
    const placement = placeBoard({
      items: items(5),
      gridSize: 3,
      centerType: CenterSquareType.NONE,
      randomize: false,
    });
    expect(ids(placement)).toEqual([
      'i0', 'i1', 'i2', 'i3', 'i4', '_', '_', '_', '_',
    ]);
  });

  it('underfilled pool on a FREE board skips the reserved center then trails nulls', () => {
    // 3x3 FREE (center idx 4 reserved). 3 items → cells 0,1,2 filled,
    // cell 4 null (reserved), cell 3 gets nothing? No — walk order:
    // cell0=i0, cell1=i1, cell2=i2, cell3=null (pool exhausted),
    // cell4=null (reserved), cells5-8=null.
    const placement = placeBoard({
      items: items(3),
      gridSize: 3,
      centerType: CenterSquareType.FREE,
      randomize: false,
    });
    expect(ids(placement)).toEqual([
      'i0', 'i1', 'i2', '_', '_', '_', '_', '_', '_',
    ]);
    expect(placement[4]).toBeNull(); // reserved center
  });

  it('overfilled pool drops the extra items (loose-fit spawn semantics)', () => {
    // 30 items on a 5x5 FREE (24 fillable) → 24 placed, 6 dropped.
    const placement = placeBoard({
      items: items(30),
      gridSize: 5,
      centerType: CenterSquareType.FREE,
      randomize: false,
    });
    const placed = placement.flatMap((t) => (t ? [t.id] : []));
    expect(placed).toHaveLength(24);
    // Order-preserving: first 24 ids, skipping the reserved center at 12.
    expect(placed).toEqual(items(24).map((t) => t.id));
  });
});

// ─── placeBoard: ordering & randomization ─────────────────────────────────────

describe('placeBoard ordering', () => {
  it('randomize:false preserves input order exactly', () => {
    const src = items(25);
    const placement = placeBoard({
      items: src,
      gridSize: 5,
      centerType: CenterSquareType.NONE,
      randomize: false,
    });
    expect(ids(placement)).toEqual(src.map((t) => t.id));
  });

  it('randomize:true with the seeded rng is deterministic (hand-verified permutation)', () => {
    // Independently derived from the LCG + fisher-yates spec (see seededRng.ts).
    // The Swift twin (BoardPlacementTests) asserts this SAME array.
    const placement = placeBoard({
      items: items(9),
      gridSize: 3,
      centerType: CenterSquareType.NONE,
      randomize: true,
      rng: makeSeededRng(7),
    });
    expect(ids(placement)).toEqual([
      'i8', 'i6', 'i1', 'i3', 'i0', 'i5', 'i4', 'i7', 'i2',
    ]);
  });

  it('5x5 FREE randomized seed 42 → hand-verified placement (center null at 12)', () => {
    const placement = placeBoard({
      items: items(24),
      gridSize: 5,
      centerType: CenterSquareType.FREE,
      randomize: true,
      rng: makeSeededRng(42),
    });
    expect(ids(placement)).toEqual([
      'i3', 'i15', 'i17', 'i16', 'i20', 'i10', 'i21', 'i1', 'i18', 'i5',
      'i9', 'i19', '_', 'i23', 'i11', 'i14', 'i13', 'i22', 'i8', 'i0',
      'i7', 'i4', 'i12', 'i2', 'i6',
    ]);
  });

  it('5x5 CHOSEN randomized seed 99 → pinned center, rest hand-verified', () => {
    // Pool is items minus the pinned center id ('c'); shuffle runs on the
    // 24-item pool, and 'c' is pinned back at cell 12 afterward.
    const withCenter = [...items(24), { id: 'c' }];
    const chosen = placeBoard({
      items: withCenter,
      gridSize: 5,
      centerType: CenterSquareType.CHOSEN,
      chosenCenterId: 'c',
      randomize: true,
      rng: makeSeededRng(99),
    });
    expect(ids(chosen)).toEqual([
      'i14', 'i15', 'i17', 'i11', 'i2', 'i19', 'i8', 'i9', 'i16', 'i18',
      'i1', 'i3', 'c', 'i20', 'i10', 'i4', 'i21', 'i22', 'i0', 'i12',
      'i7', 'i23', 'i13', 'i5', 'i6',
    ]);
  });

  it('never mutates the input items array', () => {
    const src = items(24);
    const snapshot = src.map((t) => t.id);
    placeBoard({
      items: src,
      gridSize: 5,
      centerType: CenterSquareType.FREE,
      randomize: true,
      rng: makeSeededRng(1),
    });
    expect(src.map((t) => t.id)).toEqual(snapshot);
  });
});
