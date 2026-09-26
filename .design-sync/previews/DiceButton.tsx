import { useState } from 'react';
import { DiceButton } from '@oybc/web';

const CAPTION: React.CSSProperties = {
  fontFamily: 'var(--riso-font-body)', fontSize: 11, fontWeight: 700,
  letterSpacing: '0.1em', textTransform: 'uppercase', color: 'var(--riso-muted)',
};

export function AllLevels() {
  return (
    <div style={{ display: 'flex', gap: 28, alignItems: 'flex-start' }}>
      {([0, 1, 2] as const).map((level) => (
        <div key={level} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
          <DiceButton level={level} onCycle={() => {}} />
          <span style={CAPTION}>{['Off', 'A little', 'A lot'][level]}</span>
        </div>
      ))}
    </div>
  );
}

export function InMemberRow() {
  const [level, setLevel] = useState<0 | 1 | 2>(1);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 14px', border: '2px solid var(--riso-ink)', borderRadius: 10, background: 'var(--riso-paper)', minWidth: 300 }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontFamily: 'var(--riso-font-head)', fontWeight: 700, fontSize: 14, color: 'var(--riso-ink)' }}>Run 20 miles</div>
        <div style={{ fontFamily: 'var(--riso-font-body)', fontSize: 12, color: 'var(--riso-muted)' }}>Target 20 · vary {['off', 'a little', 'a lot'][level]}</div>
      </div>
      <DiceButton level={level} onCycle={() => setLevel(((level + 1) % 3) as 0 | 1 | 2)} />
    </div>
  );
}
