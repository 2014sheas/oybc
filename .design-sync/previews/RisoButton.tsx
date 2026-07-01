import { RisoButton, RisoIcon } from '@oybc/web';

export function Kinds() {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10, alignItems: 'center' }}>
      <RisoButton kind="neutral">Neutral</RisoButton>
      <RisoButton kind="primary">Primary</RisoButton>
      <RisoButton kind="blue">Blue</RisoButton>
      <RisoButton kind="green">Green</RisoButton>
      <RisoButton kind="gold">Gold</RisoButton>
      <RisoButton kind="ghost">Ghost</RisoButton>
    </div>
  );
}

export function Sizes() {
  return (
    <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
      <RisoButton kind="primary" size="small">Small</RisoButton>
      <RisoButton kind="primary">Default</RisoButton>
      <RisoButton kind="primary" size="large">Large</RisoButton>
    </div>
  );
}

export function WithIcon() {
  return (
    <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
      <RisoButton kind="primary" icon={<RisoIcon name="plus" size={18} />}>New board</RisoButton>
      <RisoButton kind="neutral" icon={<RisoIcon name="share" size={18} />}>Share</RisoButton>
    </div>
  );
}

export function FullWidth() {
  return <RisoButton kind="green" fullWidth>Mark board complete</RisoButton>;
}

export function Disabled() {
  return <RisoButton kind="primary" disabled>Not yet</RisoButton>;
}
