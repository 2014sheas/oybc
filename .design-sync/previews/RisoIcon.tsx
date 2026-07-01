import { RisoIcon } from '@oybc/web';

const NAMES = [
  'boards', 'home', 'tasks', 'you', 'plus', 'back', 'check', 'sun', 'moon', 'share', 'sync',
  'sliders', 'repeat', 'grid', 'flame', 'shield', 'bell', 'logout', 'chevron', 'edit', 'trash', 'dots',
];

export function Gallery() {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(6, 1fr)', gap: 14, color: 'var(--riso-ink)' }}>
      {NAMES.map((n) => (
        <div key={n} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
          <RisoIcon name={n} size={24} />
          <span style={{ fontFamily: 'var(--riso-font-body)', fontSize: 10, color: 'var(--riso-muted)' }}>{n}</span>
        </div>
      ))}
    </div>
  );
}

export function Colored() {
  return (
    <div style={{ display: 'flex', gap: 18, alignItems: 'center' }}>
      <RisoIcon name="flame" size={28} style={{ color: 'var(--riso-red)' }} aria-label="streak" />
      <RisoIcon name="check" size={28} style={{ color: 'var(--riso-green)' }} aria-label="done" />
      <RisoIcon name="bell" size={28} style={{ color: 'var(--riso-blue)' }} aria-label="reminders" />
      <RisoIcon name="shield" size={28} style={{ color: 'var(--riso-achievement)' }} aria-label="achievement" />
    </div>
  );
}
