import styles from './RisoToolbarPill.module.css';

export interface RisoToolbarPillProps {
  children: string;
  onClick: () => void;
  /** Keyline + shadow colour: `--riso-ink-static` on a coloured band. Defaults to adaptive ink. */
  onBand?: boolean;
}

/**
 * RisoToolbarPill — the gold Done pill of a sheet's nav row (keyline + 2px hard
 * shadow, press into paper). iOS twin: `RisoToolbarPill`.
 *
 * @returns The pill button.
 */
export function RisoToolbarPill({ children, onClick, onBand = false }: RisoToolbarPillProps): React.ReactElement {
  return (
    <button type="button" className={`${styles.pill} ${onBand ? styles.onBand : ''}`} onClick={onClick}>
      {children}
    </button>
  );
}
