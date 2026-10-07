import { COUNT_KIND_LABELS, formatCountTotal, type CountKind } from '@oybc/shared';
import styles from './KindPicker.module.css';

export interface KindTagProps {
  kind: CountKind;
  /** The family's counter name (linked rows / auto-linking creates). */
  counterName?: string;
  /** The family's all-time total. */
  lifetime?: number;
}

/**
 * A linked row's kind: no picker, the family's kind (D5) — kind chip with the
 * shared-counter dots, then "{counter} · {all-time} all-time".
 *
 * @returns The tag row.
 */
export function KindTag({ kind, counterName, lifetime }: KindTagProps): React.ReactElement {
  return (
    <div className={styles.tagRow}>
      <span className={styles.tag}>
        {COUNT_KIND_LABELS[kind]}
        <span className={styles.dots} aria-hidden="true"><i /><i /></span>
      </span>
      {counterName && lifetime !== undefined && (
        <span className={styles.tagMeta}>{`${counterName} · ${formatCountTotal(lifetime, kind)} all-time`}</span>
      )}
    </div>
  );
}
