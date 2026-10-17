import { countUnitSuffix, type CountKind } from '@oybc/shared';
import { LogControls } from '../boardPlay/squareSheet/LogControls';
import styles from './CounterDetailLogCard.module.css';

export interface CounterDetailLogCardProps {
  kind: CountKind;
  /** The counter's unit noun (null when it has none). */
  unit: string | null;
  /** Lifetime total — "− Remove…" is disabled at 0. */
  lifetime: number;
  /** A log is in flight. */
  isLogging: boolean;
  /** Logs (or removes) an amount; the page persists every amount as the counter's default. */
  onLog: (direction: 'add' | 'remove', amount: number) => void;
}

/**
 * The Counter Detail Log card (docs/TASK_DETAIL_REDESIGN.md E3): the kind's
 * tap-to-log chips (`tapLogChips(kind)` — no goal, so no rest chip) write
 * immediately, "Other…" and "− Remove…" open the kind's entry. Mount it keyed
 * by counter id. iOS twin: `CounterDetailLogCard`.
 *
 * @returns The card.
 */
export function CounterDetailLogCard({ kind, unit, lifetime, isLogging, onLog }: CounterDetailLogCardProps): React.ReactElement {
  const unitStr = unit ?? '';
  const logTitle = `Log${countUnitSuffix(kind, unitStr)}`;
  return (
    <div className={styles.logCard} role="group" aria-label={logTitle}>
      <div className={styles.logHeader}>
        <span className={styles.logTitle}>{logTitle}</span>
      </div>
      <div className={styles.controls}>
        <LogControls
          kind={kind} unit={unitStr} goal={null} count={lifetime} size="regular" busy={isLogging}
          stripText={null} removeDisabled={lifetime === 0}
          onLog={(direction, amount) => onLog(direction, amount)} onUndo={() => undefined}
        />
      </div>
    </div>
  );
}
