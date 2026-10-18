import styles from './RisoUndoPill.module.css';

export interface RisoUndoPillProps {
  onClick: () => void;
  disabled?: boolean;
  /** Visible label; defaults to "Undo". */
  children?: string;
  /** Accessible name when the context needs one. */
  'aria-label'?: string;
}

/**
 * RisoUndoPill — the outlined "Undo" pill, promoted into the kit from the
 * wizard's member-row control. Its touch target reaches 28px tall via an
 * invisible `::before`. iOS twin: `RisoUndoPill` (RisoControls.swift).
 *
 * @returns The pill button.
 */
export function RisoUndoPill({ onClick, disabled, children = 'Undo', 'aria-label': ariaLabel }: RisoUndoPillProps): React.ReactElement {
  return (
    <button type="button" className={styles.pill} onClick={onClick} disabled={disabled} aria-label={ariaLabel}>
      {children}
    </button>
  );
}
