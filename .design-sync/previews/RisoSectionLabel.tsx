import { RisoSectionLabel } from '@oybc/web';

const HEAD = { fontFamily: 'var(--riso-font-head)', color: 'var(--riso-ink)' };

export function Section() {
  return (
    <div>
      <RisoSectionLabel>Your streaks</RisoSectionLabel>
      <div style={{ ...HEAD, fontSize: 18, fontWeight: 700, marginTop: 4 }}>12-day bingo streak</div>
    </div>
  );
}

export function Kicker() {
  return (
    <div>
      <RisoSectionLabel variant="kicker">On your bingo card</RisoSectionLabel>
      <div style={{ ...HEAD, fontSize: 24, fontWeight: 800, marginTop: 4 }}>This week's board</div>
    </div>
  );
}
