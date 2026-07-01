import { useState } from 'react';
import { RisoSegmented } from '@oybc/web';

export function Card() {
  const [v, setV] = useState('weekly');
  return (
    <RisoSegmented
      aria-label="Timeframe"
      value={v}
      onChange={setV}
      options={[
        { value: 'daily', label: 'Daily' },
        { value: 'weekly', label: 'Weekly' },
        { value: 'monthly', label: 'Monthly' },
      ]}
    />
  );
}

export function Pill() {
  const [v, setV] = useState('dark');
  return (
    <RisoSegmented
      variant="pill"
      aria-label="Theme"
      value={v}
      onChange={setV}
      options={[
        { value: 'light', label: 'Light' },
        { value: 'dark', label: 'Dark' },
      ]}
    />
  );
}
