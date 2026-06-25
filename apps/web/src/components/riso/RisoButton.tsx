import type { ButtonHTMLAttributes, ReactNode } from 'react';
import styles from './RisoButton.module.css';

/**
 * Visual kind of a Riso button.
 *
 * `neutral`/`primary`/`blue`/`green` mirror the iOS `RisoButtonKind` so the
 * two platforms stay in lockstep; `gold` and `ghost` are web-prototype
 * additions (gold highlight CTAs; ghost = transparent fill + ink keyline,
 * no shadow — the outline secondary, faithful to the prototype's `.btn.ghost`).
 */
export type RisoButtonKind = 'neutral' | 'primary' | 'blue' | 'green' | 'gold' | 'ghost';

/** Size variants. `large` for hero CTAs, `small` for dense/inline rows. */
export type RisoButtonSize = 'default' | 'large' | 'small';

export interface RisoButtonProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'className'> {
  /** Button label. */
  children: ReactNode;
  /** Visual kind. Defaults to `neutral`. */
  kind?: RisoButtonKind;
  /** Size variant. Defaults to `default`. */
  size?: RisoButtonSize;
  /** Optional leading icon (an inline SVG element). */
  icon?: ReactNode;
  /** Stretch to fill the container width. */
  fullWidth?: boolean;
}

/**
 * Primary Riso button — keyline + hard offset shadow with the
 * "press into paper" press feedback. The shared, reusable button for
 * every Riso web surface (replaces ad-hoc per-screen button styles).
 *
 * @param kind - visual fill (`neutral` default).
 * @param size - `default` | `large` | `small`.
 * @param icon - optional leading inline SVG.
 * @param fullWidth - stretch to container width.
 */
export function RisoButton({
  children,
  kind = 'neutral',
  size = 'default',
  icon,
  fullWidth = false,
  type = 'button',
  ...rest
}: RisoButtonProps): React.ReactElement {
  const className = [
    styles.btn,
    styles[kind],
    size === 'large' ? styles.large : size === 'small' ? styles.small : '',
    fullWidth ? styles.fullWidth : '',
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <button type={type} className={className} {...rest}>
      {icon}
      {children}
    </button>
  );
}
