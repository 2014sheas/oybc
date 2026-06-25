import { useState } from 'react';
import {
  RisoButton,
  RisoCard,
  RisoChip,
  RisoSegmented,
  RisoSectionLabel,
} from '../riso';

/**
 * Riso primitive-kit showcase (dev-only).
 *
 * Renders the REAL reusable Riso primitives (not throwaway markup) so the
 * Phase 0 foundation can be visually verified — token layer, both themes,
 * and each primitive's states. A local `data-theme` wrapper drives the
 * theme so the showcase works on the auth-free `/playground` route without
 * the app's `useAppliedTheme`.
 */
export function RisoKitPlayground(): React.ReactElement {
  const [dark, setDark] = useState(false);
  const [chips, setChips] = useState<string>('all');
  const [timeframe, setTimeframe] = useState<string>('weekly');
  const [size, setSize] = useState<string>('5');

  return (
    <div
      data-theme={dark ? 'dark' : 'light'}
      data-testid="riso-kit"
      style={{
        background: 'var(--riso-paper)',
        color: 'var(--riso-ink)',
        fontFamily: 'var(--riso-font-body)',
        borderRadius: 12,
        padding: 28,
        display: 'flex',
        flexDirection: 'column',
        gap: 26,
      }}
    >
      <header style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 16 }}>
        <div>
          <RisoSectionLabel variant="kicker">Riso foundation</RisoSectionLabel>
          <h2
            style={{
              fontFamily: 'var(--riso-font-head)',
              fontWeight: 800,
              fontSize: 34,
              letterSpacing: '-0.03em',
              margin: '6px 0 0',
            }}
          >
            Primitive kit
          </h2>
        </div>
        <RisoSegmented
          variant="pill"
          aria-label="Theme"
          value={dark ? 'dark' : 'light'}
          onChange={(v) => setDark(v === 'dark')}
          options={[
            { value: 'light', label: 'Day' },
            { value: 'dark', label: 'Night' },
          ]}
        />
      </header>

      {/* Buttons */}
      <section style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <RisoSectionLabel>Buttons</RisoSectionLabel>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'center' }}>
          <RisoButton kind="primary">Start a board</RisoButton>
          <RisoButton kind="neutral">Board details</RisoButton>
          <RisoButton kind="blue">Counting</RisoButton>
          <RisoButton kind="green">Compound</RisoButton>
          <RisoButton kind="gold">Bingo</RisoButton>
          <RisoButton kind="ghost">Ghost</RisoButton>
          <RisoButton kind="primary" disabled>
            Disabled
          </RisoButton>
        </div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'center' }}>
          <RisoButton kind="primary" size="large">
            Large CTA
          </RisoButton>
          <RisoButton kind="neutral" size="small">
            Small
          </RisoButton>
        </div>
      </section>

      {/* Chips */}
      <section style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <RisoSectionLabel>Chips</RisoSectionLabel>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
          {['all', 'active', 'completed', 'archived'].map((c) => (
            <RisoChip key={c} on={chips === c} onClick={() => setChips(c)}>
              {c[0].toUpperCase() + c.slice(1)}
            </RisoChip>
          ))}
        </div>
      </section>

      {/* Segmented */}
      <section style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <RisoSectionLabel>Segmented (card)</RisoSectionLabel>
        <RisoSegmented
          aria-label="Timeframe"
          value={timeframe}
          onChange={setTimeframe}
          options={[
            { value: 'daily', label: 'Daily' },
            { value: 'weekly', label: 'Weekly' },
            { value: 'monthly', label: 'Monthly' },
            { value: 'yearly', label: 'Yearly' },
          ]}
        />
        <RisoSegmented
          aria-label="Board size"
          value={size}
          onChange={setSize}
          options={[
            { value: '3', label: '3×3' },
            { value: '4', label: '4×4' },
            { value: '5', label: '5×5' },
          ]}
        />
      </section>

      {/* Cards */}
      <section style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <RisoSectionLabel>Cards</RisoSectionLabel>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 18 }}>
          <RisoCard shadow="small" padded>
            <strong style={{ fontFamily: 'var(--riso-font-head)' }}>Small shadow</strong>
            <p style={{ color: 'var(--riso-muted)', margin: '6px 0 0', fontSize: 14 }}>Dense rows</p>
          </RisoCard>
          <RisoCard padded>
            <strong style={{ fontFamily: 'var(--riso-font-head)' }}>Default card</strong>
            <p style={{ color: 'var(--riso-muted)', margin: '6px 0 0', fontSize: 14 }}>4px offset shadow</p>
          </RisoCard>
          <RisoCard shadow="large" interactive padded>
            <strong style={{ fontFamily: 'var(--riso-font-head)' }}>Large · interactive</strong>
            <p style={{ color: 'var(--riso-muted)', margin: '6px 0 0', fontSize: 14 }}>Hover + press me</p>
          </RisoCard>
        </div>
      </section>
    </div>
  );
}
