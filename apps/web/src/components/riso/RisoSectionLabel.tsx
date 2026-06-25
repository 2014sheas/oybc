import type { ReactNode } from 'react';
import styles from './RisoSectionLabel.module.css';

export interface RisoSectionLabelProps {
  children: ReactNode;
  /**
   * `section` (default) = quiet muted eyebrow over a card/section.
   * `kicker` = loud red eyebrow over a page/section headline.
   */
  variant?: 'section' | 'kicker';
}

/**
 * Riso eyebrow label — the small uppercase tracked text that tops
 * sections (`section`, muted) and headlines (`kicker`, red).
 * Mirrors the iOS `risoSectionLabel`.
 */
export function RisoSectionLabel({ children, variant = 'section' }: RisoSectionLabelProps): React.ReactElement {
  return <p className={variant === 'kicker' ? styles.kicker : styles.seclabel}>{children}</p>;
}
