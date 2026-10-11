import { unitTagLabel } from './countsTowardLabels';
import styles from './KindPicker.module.css';

export interface UnitTagProps {
  /** The counter's display name. */
  name: string;
  /** Dense scale for rows (3×8 padding, 1.5px keyline, 11px) — same as `KindTag`. */
  dense?: boolean;
}

/**
 * A unit task's counter identity: the shared-counter dots then the counter's
 * name, built from `KindTag`'s chip (shared `KindPicker.module.css`) with the
 * name in place of the kind word. Non-interactive; no kind word, no total.
 * iOS twin: `UnitTagView` in `KindPickerView.swift`.
 *
 * @returns The tag.
 */
export function UnitTag({ name, dense }: UnitTagProps): React.ReactElement {
  const label = unitTagLabel(name);
  return (
    <span className={`${styles.tag} ${dense ? styles.tagDense : ''}`} role="img" aria-label={label} title={label}>
      <span className={styles.dots} aria-hidden="true"><i /><i /></span>
      {name}
    </span>
  );
}
