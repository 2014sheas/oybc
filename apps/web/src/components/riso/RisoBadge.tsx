import type { ReactNode } from 'react';
import styles from './RisoBadge.module.css';

export type RisoBadgeKind = 'active' | 'completed' | 'draft' | 'expiring' | 'archived';

export interface RisoBadgeProps {
  kind: RisoBadgeKind;
  children: ReactNode;
}

/**
 * Riso status badge — the small uppercase pill for board/task status
 * (Active / Completed / Draft / Expiring / Archived).
 */
export function RisoBadge({ kind, children }: RisoBadgeProps): React.ReactElement {
  return <span className={`${styles.badge} ${styles[kind]}`}>{children}</span>;
}
