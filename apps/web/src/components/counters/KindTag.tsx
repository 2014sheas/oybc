import { COUNT_KIND_LABELS, formatCountTotal, type CountKind } from '@oybc/shared';
import styles from './KindPicker.module.css';

export interface KindTagProps {
  kind: CountKind;
  /** The family's counter name (linked rows / auto-linking creates). */
  counterName?: string;
  /** The family's all-time total. */
  lifetime?: number;
  /** Dense scale for dropdown rows (3×8 padding, 1.5px keyline, 11px) so a 44px row keeps its height. */
  dense?: boolean;
}

/**
 * A linked row's kind: no picker, the family's kind (D5) — kind chip with the
 * shared-counter dots, then "{counter} · {all-time} all-time".
 *
 * @returns The tag row.
 */
export function KindTag({ kind, counterName, lifetime, dense }: KindTagProps): React.ReactElement {
  return (
    <div className={`${styles.tagRow} ${dense ? styles.tagRowDense : ''}`}>
      <span className={`${styles.tag} ${dense ? styles.tagDense : ''}`}>
        {COUNT_KIND_LABELS[kind]}
        <span className={styles.dots} aria-hidden="true"><i /><i /></span>
      </span>
      {counterName && lifetime !== undefined && (
        <span className={styles.tagMeta}>{`${counterName} · ${formatCountTotal(lifetime, kind)} all-time`}</span>
      )}
    </div>
  );
}
