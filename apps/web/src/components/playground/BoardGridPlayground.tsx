import { useState } from 'react';
import { RisoChip, RisoSectionLabel, RisoSegmented } from '../riso';
import { RisoBoardGrid } from '../board/RisoBoardGrid';
import { RisoBoardCell, type BoardCellModel } from '../board/RisoBoardCell';
import { ArrangeGrid, type ArrangeSlot } from '../boardEdit/ArrangeGrid';

/**
 * Board Edit redesign slice 1 — the ONE board renderer (`RisoBoardGrid` +
 * `RisoBoardCell`) in its three states, from in-memory cell models: the
 * board as drawn, editing with staged (dirty) cells, and the arrange grid
 * where locked squares are pinned. Real components only; a local
 * `data-theme` wrapper drives the theme on the auth-free `/playground`.
 */

type State = 'board' | 'editing' | 'arrange';
type Size = 3 | 5;

const STATE_OPTIONS = [
  { value: 'board', label: 'Board' },
  { value: 'editing', label: 'Editing' },
  { value: 'arrange', label: 'Arrange' },
] as const;
const SIZE_OPTIONS = [
  { value: 3, label: '3×3' },
  { value: 5, label: '5×5' },
] as const;

const NAMES = [
  'Morning workout', 'Cook a meal', 'Call a friend', 'Read 50 pages', 'Write in journal',
  'Take a walk', 'Stretch', 'Drink 8 glasses', 'Meditate 10 min', 'Run 20 miles',
  'Weekend reset', 'No sugar', 'Sketch', 'Lights out by 11', 'Tidy the desk',
  'Plan the week', 'Practice guitar', 'Water the plants', 'Inbox zero', 'Learn 5 words',
  'Bike to work', 'Call mum', 'Floss', 'Bake bread', 'Go outside',
];

/** Sample cells: a mix of types + states, lock on two squares, dirty on two (editing only). */
function sampleCells(size: Size, state: State): BoardCellModel[] {
  const n = size * size;
  const center = Math.floor(n / 2);
  return Array.from({ length: n }, (_, i): BoardCellModel => {
    if (i === center) return { key: `free-${i}`, label: 'FREE', type: 'normal', done: true, isFree: true, isLine: false };
    const counting = i % 5 === 3;
    const compound = i % 7 === 4;
    const done = i % 3 === 0;
    const locked = i === 0 || i === n - 1;
    const dirty = state === 'editing' && (i === 1 || i === n - 2);
    const empty = state !== 'board' && i === 2;
    if (empty) return { key: `empty-${i}`, label: '', type: 'normal', done: false, isFree: false, isLine: false };
    return {
      key: `cell-${i}`,
      label: NAMES[i % NAMES.length],
      type: counting ? 'counting' : compound ? 'compound' : 'normal',
      done,
      count: counting ? { cur: done ? 20 : 7, max: 20 } : undefined,
      isFree: false,
      isLine: size === 3 && i < 3,
      locked: locked || undefined,
      dirty: dirty || undefined,
    };
  });
}

function toSlots(cells: BoardCellModel[]): ArrangeSlot[] {
  return cells.map((c) => ({
    cid: c.key,
    isCenter: c.isFree,
    isPinned: c.locked === true,
    isEmpty: c.key.startsWith('empty-'),
    model: c.key.startsWith('empty-') ? null : c,
  }));
}

export function BoardGridPlayground(): React.ReactElement {
  const [dark, setDark] = useState(false);
  const [state, setState] = useState<State>('editing');
  const [size, setSize] = useState<Size>(3);
  const [slots, setSlots] = useState<ArrangeSlot[] | null>(null);

  const cells = sampleCells(size, state);
  const arrangeSlots = slots && slots.length === cells.length ? slots : toSlots(cells);
  const lockedCount = cells.filter((c) => c.locked).length;

  return (
    <div
      data-theme={dark ? 'dark' : 'light'}
      data-testid="board-grid-playground"
      style={{
        background: 'var(--riso-paper)',
        color: 'var(--riso-ink)',
        fontFamily: 'var(--riso-font-body)',
        borderRadius: 12,
        padding: 24,
        display: 'flex',
        flexDirection: 'column',
        gap: 18,
      }}
    >
      <header style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 12 }}>
        <RisoSegmented
          options={STATE_OPTIONS}
          value={state}
          onChange={(v) => { setState(v as State); setSlots(null); }}
          variant="pill"
          aria-label="Grid state"
        />
        <RisoSegmented
          options={SIZE_OPTIONS}
          value={size}
          onChange={(v) => { setSize(v as Size); setSlots(null); }}
          variant="pill"
          aria-label="Board size"
        />
        <RisoChip on={dark} onClick={() => setDark((d) => !d)}>{dark ? 'Night press' : 'Day press'}</RisoChip>
        <RisoChip>{lockedCount} locked</RisoChip>
      </header>

      <RisoSectionLabel>
        {state === 'board' ? 'The board — lock chips persist' : state === 'editing' ? 'Editing — gold pencil = staged edit, red lock = locked' : 'Arrange — locked squares hold while the rest move'}
      </RisoSectionLabel>

      {state === 'arrange' ? (
        <ArrangeGrid slots={arrangeSlots} gridSize={size} rearrange onReorder={setSlots} />
      ) : (
        <RisoBoardGrid size={size} cellSize={90}>
          {cells.map((cell) => (
            <RisoBoardCell key={cell.key} cell={cell} onClick={state === 'editing' ? () => {} : undefined} />
          ))}
        </RisoBoardGrid>
      )}
    </div>
  );
}
