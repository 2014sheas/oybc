import { formatCount, type CountKind } from '@oybc/shared';
import { StatusPill } from '../../StatusPill';
import { LogControls } from './LogControls';
import { goalLine, heroCountSize, progressPill, restLine, restToGo } from './squareSheetModel';
import styles from './SquareSheet.module.css';

const PILL_LABELS = { completed: 'DONE', inProgress: 'IN PROGRESS', notStarted: '' };

export interface CountingBodyProps {
  count: number;
  goal: number;
  kind: CountKind;
  unit: string;
  boardLabel: string;
  busy: boolean;
  /** Closed board: the frozen count only — the caller supplies the lock row instead of the controls. */
  closedRow: React.ReactNode | null;
  stripText: string | null;
  removeDisabled: boolean;
  initialEntry?: 'add' | 'remove';
  trailing?: React.ReactNode;
  onLog: (direction: 'add' | 'remove', amount: number, persist: boolean) => void;
  onUndo: () => void;
}

/**
 * The Counting square's sheet body: the count anchored to THIS board, a
 * status pill, the bar, and the tap-to-log controls (or the closed lock row).
 *
 * @returns The body.
 */
export function CountingBody(p: CountingBodyProps): React.ReactElement {
  const done = p.goal > 0 && p.count >= p.goal;
  const pill = progressPill(done, p.count > 0);
  const rest = restToGo(p.goal, p.count);
  const fraction = p.goal > 0 ? Math.min(1, p.count / p.goal) : 0;
  return (
    <>
      <div className={styles.heroRow}>
        <span className={`${styles.count} ${styles.countBlue}`} style={{ fontSize: heroCountSize(p.kind) }}>
          {formatCount(p.count, p.kind)}
        </span>
        <span className={styles.heroLine}>{goalLine(p.goal, p.kind, p.unit, p.boardLabel)}</span>
        {pill && (
          <span className={styles.heroPill}>
            <StatusPill status={pill} dense labels={PILL_LABELS} />
          </span>
        )}
      </div>
      <div className={styles.bar} role="img" aria-label={`${formatCount(p.count, p.kind)} of ${formatCount(p.goal, p.kind)}`}>
        <div className={`${styles.barFill} ${p.count > p.goal ? styles.barFillOver : ''}`} style={{ width: `${fraction * 100}%` }} />
      </div>
      {p.closedRow ?? (
        <>
          <div className={styles.eyebrowRow}>
            <span className={styles.eyebrow}>Tap to log</span>
            {rest > 0 && <span className={styles.eyebrowRest}>{restLine(rest, p.kind, p.boardLabel)}</span>}
          </div>
          <LogControls
            kind={p.kind} unit={p.unit} goal={p.goal} count={p.count} size="regular" busy={p.busy}
            stripText={p.stripText} removeDisabled={p.removeDisabled} initialEntry={p.initialEntry} trailing={p.trailing} onLog={p.onLog} onUndo={p.onUndo}
          />
        </>
      )}
    </>
  );
}
