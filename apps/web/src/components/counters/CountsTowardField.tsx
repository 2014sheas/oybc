import { useId, useState } from 'react';
import { formatCountTotal } from '@oybc/shared';
import { useCountsTowardTargets, type CountsTowardTarget } from '../../hooks/useCountsTowardTargets';
import { BoardActionConfirmDialog } from '../boardActions/BoardActionConfirmDialog';
import { RisoIcon } from '../riso/RisoIcon';
import { RisoTypeBadge } from '../riso/RisoTypeBadge';
import { KindTag } from './KindTag';
import { COUNTS_TOWARD_LABEL, COUNTS_TOWARD_NONE } from './countsTowardLabels';
import {
  filterCountsTowardTargets,
  needsRepointConfirm,
  stepAmount,
  type CountsTowardSelection,
} from './countsTowardFieldModel';
import styles from './CountsTowardField.module.css';

export interface CountsTowardFieldProps {
  userId: string;
  /** The edited task — never its own target. Absent for a task being created. */
  taskId?: string;
  /** The task's STORED selection (drives the re-point confirm). */
  stored: CountsTowardSelection;
  value: CountsTowardSelection;
  onChange: (next: CountsTowardSelection) => void;
  /** The host sheet's field-label class (keeps the row's label in step with its neighbours). */
  labelClassName?: string;
}

/**
 * The "Counts toward" editor row (docs/SHARED_COUNTER_SETTINGS.md §3d; design
 * handoff §C2): a label + value button ("Books ›" / "None ›"), an amount
 * stepper (− N +) once a counter is set, and an inline listbox — the counter
 * search filtered to Discrete roots, "None" first, rows of name · dense
 * KindTag · "{n} all-time". Re-pointing an already-counting task asks first
 * (the confirm body is the one place the consequence is stated).
 */
export function CountsTowardField({ userId, taskId, stored, value, onChange, labelClassName }: CountsTowardFieldProps): React.ReactElement {
  const targets = useCountsTowardTargets(userId, taskId);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [pendingPick, setPendingPick] = useState<CountsTowardTarget | null>(null);
  const listId = useId();
  const current = value.counterId != null ? targets.find((t) => t.id === value.counterId) ?? null : null;
  const options = filterCountsTowardTargets(targets, query);

  const pick = (counterId: string | null): void => {
    onChange({ counterId, amount: counterId == null ? 1 : value.amount });
    setOpen(false);
    setQuery('');
  };
  const requestPick = (target: CountsTowardTarget | null): void => {
    if (target && needsRepointConfirm(stored.counterId, target.id)) {
      setPendingPick(target);
      return;
    }
    pick(target?.id ?? null);
  };
  const storedTarget = stored.counterId != null ? targets.find((t) => t.id === stored.counterId) : undefined;

  return (
    <div className={styles.field}>
      <span className={labelClassName ?? styles.label}>{COUNTS_TOWARD_LABEL}</span>
      <div className={styles.row}>
        <button
          type="button"
          className={styles.valueButton}
          aria-haspopup="listbox"
          aria-expanded={open}
          aria-controls={listId}
          aria-label={`${COUNTS_TOWARD_LABEL}: ${current?.name ?? COUNTS_TOWARD_NONE}`}
          onClick={() => setOpen((o) => !o)}
        >
          {current ? (
            <>
              <span className={styles.mark} aria-hidden="true"><i /><i /></span>
              <span className={styles.value}>{current.name}</span>
            </>
          ) : (
            <span className={styles.none}>{COUNTS_TOWARD_NONE}</span>
          )}
          <span className={styles.chevron} aria-hidden="true">›</span>
        </button>
        {current && (
          <span className={styles.stepper} role="group" aria-label="Amount">
            <button type="button" className={styles.stepBtn} aria-label="Less" onClick={() => onChange({ ...value, amount: stepAmount(value.amount, -1) })}>
              −
            </button>
            <span className={styles.amount} aria-live="polite">{value.amount}</span>
            <button type="button" className={styles.stepBtn} aria-label="More" onClick={() => onChange({ ...value, amount: stepAmount(value.amount, 1) })}>
              +
            </button>
          </span>
        )}
      </div>

      {open && (
        <div className={styles.listbox} id={listId} role="listbox" aria-label="Counters">
          <div className={styles.searchWrap}>
            <input
              type="text"
              className={styles.search}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search counters"
              aria-label="Search counters"
              autoFocus
            />
          </div>
          <button type="button" role="option" aria-selected={value.counterId == null} className={styles.option} onClick={() => requestPick(null)}>
            <span className={styles.optionNone}>{COUNTS_TOWARD_NONE}</span>
            {value.counterId == null && <span className={styles.check}><RisoIcon name="check" size={16} /></span>}
          </button>
          {options.map((t) => (
            <button key={t.id} type="button" role="option" aria-selected={t.id === value.counterId} className={styles.option} onClick={() => requestPick(t)}>
              <RisoTypeBadge type="counting" />
              <span className={styles.optionMain}>
                <span className={styles.optionName}>{t.name}</span>
                <KindTag kind={t.kind} dense />
              </span>
              <span className={styles.optionMeta}>{`${formatCountTotal(t.lifetime, t.kind)} all-time`}</span>
              {t.id === value.counterId && <span className={styles.check}><RisoIcon name="check" size={16} /></span>}
            </button>
          ))}
        </div>
      )}

      {pendingPick && (
        <BoardActionConfirmDialog
          title={`Switch to ${pendingPick.name}?`}
          body={`Earlier credits on ${storedTarget?.name ?? 'the current counter'} are withdrawn.`}
          confirmLabel="Switch"
          onCancel={() => setPendingPick(null)}
          onConfirm={() => {
            pick(pendingPick.id);
            setPendingPick(null);
          }}
        />
      )}
    </div>
  );
}
