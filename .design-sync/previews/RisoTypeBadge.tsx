import { RisoTypeBadge } from '@oybc/web';

const CAPTION: React.CSSProperties = {
  fontFamily: 'var(--riso-font-body)', fontSize: 11, fontWeight: 700,
  letterSpacing: '0.1em', textTransform: 'uppercase', color: 'var(--riso-muted)',
};

export function AllTypes() {
  const types = ['normal', 'counting', 'compound', 'achievement'] as const;
  return (
    <div style={{ display: 'flex', gap: 22, alignItems: 'flex-start' }}>
      {types.map((t) => (
        <div key={t} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
          <RisoTypeBadge type={t} />
          <span style={CAPTION}>{t}</span>
        </div>
      ))}
    </div>
  );
}

export function InTaskRows() {
  const rows = [
    { type: 'normal', title: 'Call a friend', meta: 'Normal · on 2 boards' },
    { type: 'counting', title: 'Read 100 pages', meta: 'Counting · 42 / 100' },
    { type: 'compound', title: 'Weekend reset', meta: 'Compound · 2 of 3 sub-tasks' },
    { type: 'achievement', title: 'Bingo on the monthly', meta: 'Achievement · watching September' },
  ] as const;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8, minWidth: 300 }}>
      {rows.map((r) => (
        <div key={r.title} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 14px', border: '2px solid var(--riso-ink)', borderRadius: 10, background: 'var(--riso-paper)' }}>
          <RisoTypeBadge type={r.type} />
          <div style={{ minWidth: 0 }}>
            <div style={{ fontFamily: 'var(--riso-font-head)', fontWeight: 700, fontSize: 14, color: 'var(--riso-ink)' }}>{r.title}</div>
            <div style={{ fontFamily: 'var(--riso-font-body)', fontSize: 12, color: 'var(--riso-muted)' }}>{r.meta}</div>
          </div>
        </div>
      ))}
    </div>
  );
}
