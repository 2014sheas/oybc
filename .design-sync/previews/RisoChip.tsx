import { useState } from 'react';
import { RisoChip } from '@oybc/web';

export function FilterRow() {
  const [sel, setSel] = useState('active');
  const opts = ['all', 'active', 'completed'];
  return (
    <div style={{ display: 'flex', gap: 8 }}>
      {opts.map((o) => (
        <RisoChip key={o} on={sel === o} onClick={() => setSel(o)}>
          {o[0].toUpperCase() + o.slice(1)}
        </RisoChip>
      ))}
    </div>
  );
}

export function States() {
  return (
    <div style={{ display: 'flex', gap: 8 }}>
      <RisoChip>Unselected</RisoChip>
      <RisoChip on>Selected</RisoChip>
    </div>
  );
}
