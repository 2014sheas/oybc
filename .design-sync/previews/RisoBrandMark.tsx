import { RisoBrandMark } from '@oybc/web';

export function Default() {
  return <RisoBrandMark />;
}

export function Sizes() {
  return (
    <div style={{ display: 'flex', gap: 20, alignItems: 'center' }}>
      <RisoBrandMark size={28} />
      <RisoBrandMark size={40} />
      <RisoBrandMark size={64} />
    </div>
  );
}
