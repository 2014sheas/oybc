import type { HTMLAttributes, ReactNode } from 'react';
import styles from './RisoCard.module.css';

/** Hard-shadow depth. `small` for dense rows, `large` for hero posters. */
export type RisoCardShadow = 'small' | 'default' | 'large';

export interface RisoCardProps extends HTMLAttributes<HTMLDivElement> {
  children: ReactNode;
  /** Shadow depth. Defaults to `default` (4px). */
  shadow?: RisoCardShadow;
  /** Add hover-lift + press feedback (use for tappable cards). */
  interactive?: boolean;
  /** Apply the convenience 16px inner padding. */
  padded?: boolean;
  /** Extra class names to merge (e.g. a screen-specific layout module). */
  className?: string;
}

/**
 * Riso card / panel — the reusable container surface (keyline + paper-2 fill
 * + hard offset shadow). Mirrors the iOS `.risoCard()` modifier.
 *
 * @param shadow - depth of the hard offset shadow.
 * @param interactive - enable hover-lift/press feedback for tappable cards.
 * @param padded - apply the convenience inner padding.
 */
export function RisoCard({
  children,
  shadow = 'default',
  interactive = false,
  padded = false,
  className,
  ...rest
}: RisoCardProps): React.ReactElement {
  const classes = [
    styles.card,
    shadow === 'small' ? styles.small : shadow === 'large' ? styles.large : '',
    interactive ? styles.interactive : '',
    padded ? styles.pad : '',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <div className={classes} {...rest}>
      {children}
    </div>
  );
}
