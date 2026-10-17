import { useState } from 'react';
import { parseCountInput, tapLogChips, type CountKind, type TapLogChip } from '@oybc/shared';
import { GoalEntry } from '../../counters/GoalEntry';
import { RisoButton, TapLogChipRow, UndoStrip } from '../../riso';
import { entryAmount } from './squareSheetModel';
import styles from './LogControls.module.css';

export interface LogControlsProps {
  kind: CountKind;
  unit: string;
  /** The square's goal in this window, if any (drives the `+rest ✓` chip). */
  goal: number | null;
  /** The windowed count the rest is measured from. */
  count: number;
  size: 'regular' | 'compact';
  /** A write is in flight — chips, entry and Undo disable, never hide. */
  busy: boolean;
  /** The Undo strip's line; absent = no strip. */
  stripText: string | null;
  /** The "− Remove…" link (regular size only). */
  removeDisabled?: boolean;
  /** `persist` is true only for an explicit "Other…" add (the existing default-amount rule). */
  onLog: (direction: 'add' | 'remove', amount: number, persist: boolean) => void;
  onUndo: () => void;
}

/**
 * The one-gesture log control shared by the counting hero and a compound's
 * counting child: `TapLogChipRow` (a chip writes at once), the kind's entry
 * for "Other…" / "− Remove…", and the inline `UndoStrip`.
 *
 * @returns The controls.
 */
export function LogControls({
  kind, unit, goal, count, size, busy, stripText, removeDisabled, onLog, onUndo,
}: LogControlsProps): React.ReactElement {
  const [entry, setEntry] = useState<{ mode: 'add' | 'remove'; draft: string } | null>(null);
  const amount = entry ? entryAmount(parseCountInput(entry.draft, kind)) : null;
  const chips = tapLogChips(kind, goal, count);

  function onChip(chip: TapLogChip): void {
    if (chip.value === null) {
      setEntry({ mode: 'add', draft: '' });
      return;
    }
    onLog('add', chip.value, false);
  }

  function commit(): void {
    if (!entry || amount === null) return;
    onLog(entry.mode, amount, entry.mode === 'add');
    setEntry(null);
  }

  return (
    <>
      <TapLogChipRow chips={chips} size={size} disabled={busy} onChip={onChip} unit={kind === 'duration' ? '' : unit} label="Log amount" />
      {entry && (
        <div className={styles.entryRow}>
          <div className={styles.entryField}>
            <GoalEntry
              kind={kind}
              value={entry.draft}
              onChange={(draft) => setEntry({ ...entry, draft })}
              aria-label={entry.mode === 'add' ? 'Custom amount' : 'Amount to remove'}
              placeholder="Amount"
              suffix={kind === 'duration' || !unit ? undefined : unit}
              dense
              autoFocus
              invalid={entry.draft.trim() !== '' && amount === null}
              onEnter={commit}
              onEscape={() => setEntry(null)}
            />
          </div>
          <RisoButton size="small" kind="gold" disabled={busy || amount === null} onClick={commit}>
            {entry.mode === 'add' ? 'Log' : 'Remove'}
          </RisoButton>
        </div>
      )}
      {stripText && <UndoStrip text={stripText} onUndo={onUndo} disabled={busy} compact={size === 'compact'} />}
      {size === 'regular' && (
        <div className={styles.removeRow}>
          <button
            type="button"
            className={styles.removeLink}
            disabled={busy || removeDisabled}
            onClick={() => setEntry({ mode: 'remove', draft: '' })}
          >
            − Remove…
          </button>
        </div>
      )}
    </>
  );
}
