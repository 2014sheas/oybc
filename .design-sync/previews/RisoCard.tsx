import { RisoCard, RisoSectionLabel, RisoButton } from '@oybc/web';

const HEAD = { fontFamily: 'var(--riso-font-head)', color: 'var(--riso-ink)' };
const BODY = { fontFamily: 'var(--riso-font-body)' };

export function Shadows() {
  return (
    <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', alignItems: 'flex-start' }}>
      {['small', 'default', 'large'].map((s) => (
        <RisoCard key={s} shadow={s} padded>
          <RisoSectionLabel>{s} shadow</RisoSectionLabel>
          <div style={{ ...HEAD, fontWeight: 600, marginTop: 4 }}>Weekly reset</div>
        </RisoCard>
      ))}
    </div>
  );
}

export function Padded() {
  return (
    <RisoCard padded>
      <RisoSectionLabel variant="kicker">This week</RisoSectionLabel>
      <div style={{ ...HEAD, fontSize: 20, fontWeight: 700, margin: '6px 0' }}>Morning routine</div>
      <div style={{ ...BODY, color: 'var(--riso-muted)', marginBottom: 12 }}>
        4 of 9 squares complete — one line to bingo.
      </div>
      <RisoButton kind="primary" size="small">Open board</RisoButton>
    </RisoCard>
  );
}

export function Interactive() {
  return (
    <RisoCard interactive padded>
      <div style={{ ...HEAD, fontWeight: 600 }}>Tappable card</div>
      <div style={{ ...BODY, color: 'var(--riso-muted)' }}>Hover for the lift + press feedback.</div>
    </RisoCard>
  );
}
