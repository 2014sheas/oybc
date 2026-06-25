import type { ButtonHTMLAttributes, ReactNode } from 'react';
import styles from './RisoChip.module.css';

export interface RisoChipProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'className'> {
  children: ReactNode;
  /** Selected/active state — inverts the chip to ink fill. */
  on?: boolean;
}

/**
 * Riso chip — the pill used for filter rows and segmented toggles
 * (e.g. All / Active / Completed). Mirrors the iOS `RisoChip`.
 *
 * @param on - whether the chip is selected (ink fill, cream text).
 */
export function RisoChip({ children, on = false, type = 'button', ...rest }: RisoChipProps): React.ReactElement {
  const className = [styles.chip, on ? styles.on : ''].filter(Boolean).join(' ');
  return (
    <button type={type} className={className} aria-pressed={on} {...rest}>
      {children}
    </button>
  );
}
