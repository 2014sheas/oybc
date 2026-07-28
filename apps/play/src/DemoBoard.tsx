import { useCallback, useEffect, useState } from 'react';
import {
  placeBoard,
  detectBingos,
  getHighlightedSquares,
  formatBingoMessage,
  CenterSquareType,
} from '@oybc/bingo-core';

/**
 * DemoBoard — a dependency-chain proof, not product code.
 *
 * Exercises the full `@oybc/bingo-core` + `@oybc/riso-tokens` chain end to
 * end: `placeBoard` for layout, click-to-toggle completion, `detectBingos` +
 * `getHighlightedSquares` for line detection, `formatBingoMessage` for the
 * banner. Styling uses Riso token CSS custom properties only (no kit
 * primitives — those live in Do's `components/riso`, which Play doesn't
 * depend on). The realtime session model is out of scope here; see
 * `docs/play/PLAY_OYBC.md`.
 */

const GRID_SIZE = 5 as const;
const CENTER_INDEX = 12; // floor(5*5/2) — the reserved FREE center of a 5x5 board.

interface PartyTask {
  id: string;
  title: string;
}

const PARTY_TASKS: PartyTask[] = [
  { id: 't1', title: 'Do the worm' },
  { id: 't2', title: 'Speak in an accent for 5 min' },
  { id: 't3', title: 'Take a shot of hot sauce' },
  { id: 't4', title: 'Sing the chorus of a song' },
  { id: 't5', title: 'Give someone a piggyback ride' },
  { id: 't6', title: 'Trade shoes with someone' },
  { id: 't7', title: 'Do 10 pushups' },
  { id: 't8', title: 'Tell a joke that lands' },
  { id: 't9', title: 'Balance a spoon on your nose' },
  { id: 't10', title: 'Text a random emoji to a friend' },
  { id: 't11', title: 'Do an impression of someone here' },
  { id: 't12', title: 'Freestyle rap for 15 seconds' },
  { id: 't13', title: 'Let someone draw on your hand' },
  { id: 't14', title: 'Guess a stranger’s job' },
  { id: 't15', title: 'Speak only in questions for 2 min' },
  { id: 't16', title: 'Do your best celebrity impression' },
  { id: 't17', title: 'Hold a plank for 30 seconds' },
  { id: 't18', title: 'Swap seats with someone' },
  { id: 't19', title: 'Name 5 countries in 10 seconds' },
  { id: 't20', title: 'Do a cartwheel (or try to)' },
  { id: 't21', title: 'Talk like a pirate for a round' },
  { id: 't22', title: 'Draw a self-portrait blind' },
  { id: 't23', title: 'Recite the alphabet backwards' },
  { id: 't24', title: 'Make up a secret handshake' },
  { id: 't25', title: 'Do your best robot dance' },
  { id: 't26', title: 'Compliment three people' },
  { id: 't27', title: 'Whistle a tune' },
  { id: 't28', title: 'Act out an animal, others guess' },
  { id: 't29', title: 'Tell an embarrassing story' },
  { id: 't30', title: 'Lead a group cheer' },
];

export default function DemoBoard() {
  const [cells, setCells] = useState<(PartyTask | null)[]>([]);
  const [marked, setMarked] = useState<Set<number>>(new Set([CENTER_INDEX]));

  const newBoard = useCallback(() => {
    const placed = placeBoard({
      items: PARTY_TASKS,
      gridSize: GRID_SIZE,
      centerType: CenterSquareType.FREE,
      randomize: true,
    });
    setCells(placed);
    // FREE center is auto-completed — always in the completion grid.
    setMarked(new Set([CENTER_INDEX]));
  }, []);

  useEffect(() => {
    newBoard();
  }, [newBoard]);

  const toggle = (index: number) => {
    if (index === CENTER_INDEX) return; // FREE center is locked on.
    setMarked((prev) => {
      const next = new Set(prev);
      if (next.has(index)) {
        next.delete(index);
      } else {
        next.add(index);
      }
      return next;
    });
  };

  const completionGrid = Array.from({ length: GRID_SIZE * GRID_SIZE }, (_, i) => marked.has(i));
  const result = detectBingos(completionGrid, GRID_SIZE);
  const highlighted = getHighlightedSquares(result.completedLines, GRID_SIZE);
  const banner = formatBingoMessage(result);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '1rem', maxWidth: 480 }}>
      <h1 style={{ fontFamily: 'var(--riso-font-head)', fontSize: '1.5rem' }}>Play OYBC — demo board</h1>
      <p style={{ color: 'var(--riso-muted)', textAlign: 'center', fontSize: '0.9rem' }}>
        Dependency-chain proof: layout + detection from @oybc/bingo-core, styled with @oybc/riso-tokens only.
      </p>
      {banner && (
        <div
          style={{
            background: 'var(--riso-gold)',
            color: 'var(--riso-ink-static)',
            border: '2px solid var(--riso-ink)',
            borderRadius: 'var(--riso-r-card)',
            padding: '0.5rem 1rem',
            fontFamily: 'var(--riso-font-head)',
            fontWeight: 700,
          }}
        >
          {banner}
        </div>
      )}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: `repeat(${GRID_SIZE}, 1fr)`,
          gap: '0.4rem',
          width: '100%',
        }}
      >
        {cells.map((cell, i) => {
          const isCenter = i === CENTER_INDEX;
          const isMarked = marked.has(i);
          const isHighlighted = highlighted.has(i);
          return (
            <button
              key={i}
              onClick={() => toggle(i)}
              style={{
                aspectRatio: '1',
                background: isHighlighted
                  ? 'var(--riso-gold)'
                  : isMarked
                    ? 'var(--riso-green)'
                    : 'var(--riso-paper-2)',
                color: isMarked || isHighlighted ? 'var(--riso-on-color)' : 'var(--riso-ink)',
                border: '2px solid var(--riso-ink)',
                borderRadius: 'var(--riso-r-cell)',
                fontFamily: 'var(--riso-font-body)',
                fontSize: '0.65rem',
                fontWeight: isCenter ? 700 : 500,
                padding: '0.25rem',
                cursor: isCenter ? 'default' : 'pointer',
              }}
            >
              {isCenter ? 'FREE' : (cell?.title ?? '')}
            </button>
          );
        })}
      </div>
      <button
        onClick={newBoard}
        style={{
          background: 'var(--riso-red)',
          color: 'var(--riso-on-color)',
          border: '2px solid var(--riso-ink)',
          borderRadius: 'var(--riso-r-card)',
          padding: '0.6rem 1.2rem',
          fontFamily: 'var(--riso-font-head)',
          fontWeight: 700,
          cursor: 'pointer',
        }}
      >
        New board
      </button>
    </div>
  );
}
