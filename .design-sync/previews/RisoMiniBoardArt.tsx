import { RisoMiniBoardArt } from '@oybc/web';

export function Default() {
  return <RisoMiniBoardArt />;
}

export function Large() {
  return <RisoMiniBoardArt cellSize={40} />;
}

export function EmptyState() {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14, padding: 24, textAlign: 'center', maxWidth: 320 }}>
      <RisoMiniBoardArt cellSize={30} />
      <div style={{ fontFamily: 'var(--riso-font-head)', fontWeight: 800, fontSize: 20, color: 'var(--riso-ink)' }}>Nothing here yet.</div>
      <div style={{ fontFamily: 'var(--riso-font-body)', fontSize: 14, lineHeight: 1.45, color: 'var(--riso-muted)' }}>
        Start one — pick a timeframe, drop in your tasks, and print the board.
      </div>
    </div>
  );
}
