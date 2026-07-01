import { RisoBadge } from '@oybc/web';

export function AllKinds() {
  return (
    <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
      <RisoBadge kind="active">Active</RisoBadge>
      <RisoBadge kind="completed">Completed</RisoBadge>
      <RisoBadge kind="draft">Draft</RisoBadge>
      <RisoBadge kind="expiring">Expiring</RisoBadge>
      <RisoBadge kind="archived">Archived</RisoBadge>
    </div>
  );
}
